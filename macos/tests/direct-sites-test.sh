#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export DIRECT_ROUTING_LIB_ONLY=1
. "$ROOT/macos/direct-sites.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { printf '%s' "$1" | grep -F "$2" >/dev/null || fail "$3 (missing: $2)"; }

validate_config "$ROOT/direct-sites.json" || fail 'central config should validate'
if validate_config "$ROOT/tests/fixtures/invalid-version.json"; then fail 'unknown version should fail'; fi

rules=$(render_stash_rules "$ROOT/direct-sites.json")
assert_contains "$rules" 'DOMAIN-SUFFIX,moysklad.ru,DIRECT' 'Stash rules should render'

resolved=$(mktemp)
trap 'rm -f "$resolved"' EXIT
printf 'moysklad.ru\t185.246.65.191\n' > "$resolved"
hosts=$(render_hosts_block "$ROOT/direct-sites.json" "$resolved")
assert_contains "$hosts" '83.217.192.28 maily.life' 'fixed host should render'
assert_contains "$hosts" '185.246.65.191 moysklad.ru' 'resolved direct host should render'

commands=$(render_route_commands "$ROOT/direct-sites.json" '192.168.0.1' '185.246.65.191')
assert_contains "$commands" 'route -n add -host 83.217.192.28 192.168.0.1' 'fixed route should render'
assert_contains "$commands" 'route -n add -host 185.246.65.191 192.168.0.1' 'resolved route should render'

existing='127.0.0.1 localhost
# BEGIN LANPRO DIRECT ROUTING
old
# END LANPRO DIRECT ROUTING'
updated=$(replace_managed_hosts "$existing" "$hosts")
assert_contains "$updated" '127.0.0.1 localhost' 'unmanaged host should remain'
if printf '%s' "$updated" | grep -Fx old >/dev/null; then fail 'old block should be removed'; fi
[ "$(printf '%s' "$updated" | grep -c '^# BEGIN LANPRO DIRECT ROUTING$')" -eq 1 ] || fail 'managed block duplicated'

echo 'PASS macOS client tests'
