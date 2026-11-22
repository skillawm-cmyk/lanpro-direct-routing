#!/usr/bin/env python3
import http.client
import json
import os
import shutil
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIRECT = ("lanpro.uz", "www.lanpro.uz", "example.su", "sub.anything.ru", "api.bitrix24.net", "www.goofish.com", "a.timeweb.cloud", "api.wechat.com")
PROXY = ("example.net", "ru.example.net", "notbitrix24.net", "evilwechat.com", "lanpro.uz.example.net")


class HttpOrigin(socketserver.StreamRequestHandler):
    def handle(self):
        self.server.visits += 1
        while self.rfile.readline() not in (b"\r\n", b""):
            pass
        self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nDIRECT")


class TestSocks(socketserver.StreamRequestHandler):
    def handle(self):
        version, count = self.rfile.read(2)
        assert version == 5 and 0 in self.rfile.read(count)
        self.wfile.write(b"\x05\x00")
        version, cmd, _, kind = self.rfile.read(4)
        assert (version, cmd, kind) == (5, 1, 3)
        name = self.rfile.read(self.rfile.read(1)[0]).decode("ascii")
        self.rfile.read(2)
        self.server.visits.append(name)
        if self.server.refuse:
            self.wfile.write(b"\x05\x05\x00\x01" + bytes(6))
            return
        self.wfile.write(b"\x05\x00\x00\x01" + bytes(6))
        while self.rfile.readline() not in (b"\r\n", b""):
            pass
        self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\nUSA-SOCKS")


class MihomoTest(unittest.TestCase):
    def start_server(self, handler):
        server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server

    def test_real_engine_direct_proxy_and_no_fallback(self):
        mihomo = os.environ["MIHOMO_BIN"]
        origin = self.start_server(HttpOrigin)
        origin.visits = 0
        socks = self.start_server(TestSocks)
        socks.visits = []
        socks.refuse = False
        template = json.loads((ROOT / "windows/profile.template.json").read_text())

        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            provider = home / "rule-providers/lanpro-direct.yaml"
            provider.parent.mkdir()
            shutil.copyfile(ROOT / "stash/direct-rules.yaml", provider)
            path = home / "config.json"
            template["proxies"][1]["server"] = "100.64.0.10"
            path.write_text(json.dumps(template))
            tested = subprocess.run([mihomo, "-t", "-d", tmp, "-f", str(path)], capture_output=True, text=True, timeout=20)
            self.assertEqual(tested.returncode, 0, tested.stdout + tested.stderr)

            # Preserve the real rules; substitute loopback endpoints and disable TUN/DNS for unprivileged CI.
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                listen = reservation.getsockname()[1]
            template["mixed-port"] = listen
            template["tun"]["enable"] = False
            template["dns"]["enable"] = False
            template["hosts"] = dict.fromkeys(DIRECT, "127.0.0.1")
            template["proxies"] = [{"name": "USA-SOCKS", "type": "socks5", "server": "127.0.0.1", "port": socks.server_address[1]}]
            template["rule-providers"]["lanpro-direct"] = {"type": "file", "behavior": "classical", "path": "./rule-providers/lanpro-direct.yaml"}
            path.write_text(json.dumps(template))
            with tempfile.TemporaryFile() as log:
                process = subprocess.Popen([mihomo, "-d", tmp, "-f", str(path)], stdout=log, stderr=subprocess.STDOUT)
                try:
                    for _ in range(100):
                        try:
                            socket.create_connection(("127.0.0.1", listen), timeout=0.1).close()
                            break
                        except OSError:
                            if process.poll() is not None:
                                self.fail("Mihomo exited before listening")
                            time.sleep(0.05)
                    else:
                        self.fail("Mihomo did not start")

                    def request(name):
                        conn = http.client.HTTPConnection("127.0.0.1", listen, timeout=5)
                        try:
                            conn.request("GET", f"http://{name}:{origin.server_address[1]}/")
                            response = conn.getresponse()
                            return response.status, response.read()
                        finally:
                            conn.close()

                    for name in DIRECT:
                        self.assertEqual(request(name), (200, b"DIRECT"), name)
                    self.assertEqual(socks.visits, [])
                    for name in PROXY:
                        self.assertEqual(request(name), (200, b"USA-SOCKS"), name)
                    self.assertEqual(socks.visits, list(PROXY))
                    socks.refuse = True
                    self.assertNotEqual(request("example.net")[0], 200)
                    self.assertEqual(request("lanpro.uz"), (200, b"DIRECT"))
                    self.assertEqual(origin.visits, len(DIRECT) + 1)
                except Exception:
                    log.seek(0)
                    print(log.read().decode(errors="replace"))
                    raise
                finally:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
