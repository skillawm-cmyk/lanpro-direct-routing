#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

for file in README.md install-macos.sh install-windows.ps1 stash/direct-rules.yaml stash/config-snippet.yaml .github/workflows/test.yml; do
  [ -s "$ROOT/$file" ] || { echo "FAIL missing $file" >&2; exit 1; }
done

grep -F 'skillawm-cmyk/lanpro-direct-routing' "$ROOT/install-macos.sh" >/dev/null
grep -F 'skillawm-cmyk/lanpro-direct-routing' "$ROOT/install-windows.ps1" >/dev/null
grep -F 'DOMAIN-SUFFIX,ru' "$ROOT/stash/direct-rules.yaml" >/dev/null
grep -F 'DOMAIN-SUFFIX,su' "$ROOT/stash/direct-rules.yaml" >/dev/null
grep -F 'RULE-SET,lanpro-direct,DIRECT' "$ROOT/stash/config-snippet.yaml" >/dev/null
python3 "$ROOT/tests/check-stash-rules.py"

if rg -n --hidden -g '!tests/package-check.sh' '(ghp_[A-Za-z0-9]{20,}|github_pat_|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|password\s*[:=]\s*[^$<])' "$ROOT"; then
  echo 'FAIL possible secret found' >&2
  exit 1
fi

echo 'PASS package checks'
