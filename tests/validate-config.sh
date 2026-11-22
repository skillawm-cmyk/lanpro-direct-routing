#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 "$ROOT/tests/validate-config.py" \
  "$ROOT/direct-sites.json" \
  "$ROOT/tests/fixtures/"*.json
