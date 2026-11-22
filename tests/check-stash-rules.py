#!/usr/bin/env python3
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
config = json.loads((root / "direct-sites.json").read_text(encoding="utf-8"))
expected = ["payload:"] + [f"  - {r['type']},{r['value']}" for r in config["rules"]]
actual = (root / "stash" / "direct-rules.yaml").read_text(encoding="utf-8").splitlines()
if actual != expected:
    raise SystemExit("stash/direct-rules.yaml is not synchronized with direct-sites.json")
print("PASS Stash rules synchronized")
