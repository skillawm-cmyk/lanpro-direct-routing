#!/usr/bin/env python3
import ipaddress
import json
import re
import sys
from pathlib import Path


DOMAIN_RE = re.compile(r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")


def validate(path: Path) -> list[str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    errors: list[str] = []
    if data.get("version") != 1:
        errors.append("unsupported version")
    routes = data.get("routes")
    if not isinstance(routes, list) or not routes:
        return errors + ["routes must be a non-empty array"]

    seen_ips: set[str] = set()
    domain_ips: dict[str, str] = {}
    for index, route in enumerate(routes):
        if not isinstance(route, dict):
            errors.append(f"route {index} must be an object")
            continue
        ip = route.get("ipv4")
        try:
            if str(ipaddress.ip_address(ip)).count(":"):
                raise ValueError
        except (ValueError, TypeError):
            errors.append(f"route {index} has invalid IPv4")
            continue
        if ip in seen_ips:
            errors.append(f"duplicate route IPv4: {ip}")
        seen_ips.add(ip)

        domains = route.get("domains")
        if not isinstance(domains, list):
            errors.append(f"route {index} domains must be an array")
            continue
        for domain in domains:
            if not isinstance(domain, str) or not DOMAIN_RE.fullmatch(domain):
                errors.append(f"invalid domain: {domain}")
                continue
            previous = domain_ips.get(domain)
            if previous is not None:
                label = "duplicate domain" if previous == ip else "conflicting domain"
                errors.append(f"{label}: {domain}")
            domain_ips[domain] = ip
        if not isinstance(route.get("include_www"), bool):
            errors.append(f"route {index} include_www must be boolean")
        if not isinstance(route.get("enabled"), bool):
            errors.append(f"route {index} enabled must be boolean")
    return errors


if __name__ == "__main__":
    failures = 0
    for filename in sys.argv[1:]:
        path = Path(filename)
        expected_valid = path.name.startswith("valid-") or path.name == "direct-sites.json"
        try:
            errors = validate(path)
        except (OSError, json.JSONDecodeError) as exc:
            errors = [str(exc)]
        actual_valid = not errors
        if actual_valid != expected_valid:
            failures += 1
            print(f"FAIL {path}: expected {'valid' if expected_valid else 'invalid'}; {errors or 'no errors'}")
        else:
            print(f"PASS {path}")
    raise SystemExit(1 if failures else 0)
