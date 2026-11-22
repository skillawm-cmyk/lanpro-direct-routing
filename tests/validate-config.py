#!/usr/bin/env python3
import ipaddress
import json
import re
import sys
from pathlib import Path


DOMAIN_RE = re.compile(r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
TLD_RE = re.compile(r"^[a-z]{2,63}$")


def validate(path: Path) -> list[str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    errors: list[str] = []
    if data.get("version") != 1:
        errors.append("unsupported version")
    rules = data.get("rules")
    if not isinstance(rules, list) or not rules:
        errors.append("rules must be a non-empty array")
    else:
        seen_rules: set[tuple[str, str]] = set()
        for index, rule in enumerate(rules):
            if not isinstance(rule, dict):
                errors.append(f"rule {index} must be an object")
                continue
            rule_type = rule.get("type")
            value = rule.get("value")
            if rule_type not in {"DOMAIN", "DOMAIN-SUFFIX"}:
                errors.append(f"rule {index} has invalid type")
            valid_value = isinstance(value, str) and (
                DOMAIN_RE.fullmatch(value) or (rule_type == "DOMAIN-SUFFIX" and TLD_RE.fullmatch(value))
            )
            if not valid_value:
                errors.append(f"rule {index} has invalid domain")
                continue
            key = (rule_type, value)
            if key in seen_rules:
                errors.append(f"duplicate rule: {rule_type},{value}")
            seen_rules.add(key)
            if rule.get("policy") != "DIRECT":
                errors.append(f"rule {index} policy must be DIRECT")
    routes = data.get("fixed_routes")
    if not isinstance(routes, list) or not routes:
        return errors + ["fixed_routes must be a non-empty array"]

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
            if path.name == "direct-sites.json" and not errors:
                data = json.loads(path.read_text(encoding="utf-8"))
                actual = {(rule["type"], rule["value"], rule["policy"]) for rule in data["rules"]}
                expected_path = path.parent / "tests" / "expected-rules.txt"
                expected = {
                    tuple(line.strip().split(","))
                    for line in expected_path.read_text(encoding="utf-8").splitlines()
                    if line.strip() and not line.startswith("#")
                }
                missing = sorted(expected - actual)
                if missing:
                    errors.append(f"missing central rules: {missing}")
        except (OSError, json.JSONDecodeError) as exc:
            errors = [str(exc)]
        actual_valid = not errors
        if actual_valid != expected_valid:
            failures += 1
            print(f"FAIL {path}: expected {'valid' if expected_valid else 'invalid'}; {errors or 'no errors'}")
        else:
            print(f"PASS {path}")
    raise SystemExit(1 if failures else 0)
