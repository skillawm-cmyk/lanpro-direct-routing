#!/usr/bin/env python3
import json
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ROUTES = ["RULE-SET,lanpro-direct,DIRECT", "MATCH,USA-SOCKS"]
PROVIDER_URL = "https://raw.githubusercontent.com/skillawm-cmyk/lanpro-direct-routing/main/stash/direct-rules.yaml"


def read_yaml(relative):
    return json.loads(subprocess.check_output([
        "ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.safe_load(File.read(ARGV.fetch(0))))",
        str(ROOT / relative),
    ], text=True))


class PolicyTest(unittest.TestCase):
    def test_stash_and_mihomo_have_one_terminal_socks_rule(self):
        stash = read_yaml("stash/config-snippet.yaml")
        windows = json.loads((ROOT / "windows/profile.template.json").read_text())
        for profile in (stash, windows):
            self.assertEqual(profile["mode"], "rule")
            expected = ROUTES if profile is stash else [ROUTES[0], "NETWORK,udp,REJECT", ROUTES[1]]
            self.assertEqual(profile["rules"], expected)
            provider = profile["rule-providers"]["lanpro-direct"]
            self.assertEqual(provider["url"], PROVIDER_URL)
            self.assertEqual(provider["behavior"], "classical")
        self.assertEqual(stash["dns"]["follow-rule"], False)
        self.assertEqual(windows["rule-providers"]["lanpro-direct"]["proxy"], "USA-SOCKS")
        self.assertEqual(windows["dns"]["direct-nameserver"], ["https://1.1.1.1/dns-query#DIRECT"])
        self.assertEqual(windows["dns"]["nameserver"], ["https://1.1.1.1/dns-query#USA-SOCKS"])
        self.assertEqual(windows["dns"]["enhanced-mode"], "fake-ip")
        self.assertEqual(windows["dns"]["nameserver-policy"], {"rule-set:lanpro-direct": "https://1.1.1.1/dns-query#DIRECT"})
        self.assertEqual(windows["tun"]["enable"], True)
        self.assertEqual(windows["tun"]["strict-route"], True)
        self.assertEqual(windows["allow-lan"], False)
        self.assertNotIn("external-controller", windows)
        tailnet, socks = windows["proxies"]
        self.assertEqual(tailnet["type"], "tailscale")
        self.assertNotIn("exit-node", tailnet)
        self.assertNotIn("auth-key", tailnet)
        self.assertEqual(socks["dialer-proxy"], tailnet["name"])
        self.assertNotIn("proxy-groups", windows)

    def test_provider_only_accepts_unique_domain_rules(self):
        data = read_yaml("stash/direct-rules.yaml")
        self.assertEqual(set(data), {"payload"})
        rules = data["payload"]
        self.assertEqual(len(rules), len(set(rules)))
        for rule in rules:
            kind, value = rule.split(",")
            self.assertIn(kind, {"DOMAIN", "DOMAIN-SUFFIX"})
            if value in ("ru", "su"):
                self.assertEqual(kind, "DOMAIN-SUFFIX")
            else:
                self.assertRegex(value, re.compile(r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"))
        expected = {line.removesuffix(",DIRECT") for line in (ROOT / "tests/expected-rules.txt").read_text().splitlines()}
        self.assertTrue(expected <= set(rules), sorted(expected - set(rules)))


if __name__ == "__main__":
    unittest.main()
