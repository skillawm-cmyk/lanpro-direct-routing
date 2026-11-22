#!/bin/sh
set -eu

COMMAND=${1:-status}
TARGET=${2:-}
CONFIG_URL=${DIRECT_ROUTING_CONFIG_URL:-https://raw.githubusercontent.com/skillawm-cmyk/lanpro-direct-routing/main/direct-sites.json}
STATE_DIR=${DIRECT_ROUTING_STATE_DIR:-/Library/Application Support/LanproDirectRouting}
HOSTS_PATH=${DIRECT_ROUTING_HOSTS_PATH:-/etc/hosts}
BEGIN_MARKER='# BEGIN LANPRO DIRECT ROUTING'
END_MARKER='# END LANPRO DIRECT ROUTING'

validate_config() {
  python3 - "$1" <<'PY'
import ipaddress, json, re, sys
domain_re = re.compile(r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$')
tld_re = re.compile(r'^[a-z]{2,63}$')
try:
    data = json.load(open(sys.argv[1], encoding='utf-8'))
    assert data.get('version') == 1
    rules = data.get('rules')
    routes = data.get('fixed_routes')
    assert isinstance(rules, list) and rules
    assert isinstance(routes, list) and routes
    seen_rules, seen_ips, seen_domains = set(), set(), set()
    for rule in rules:
        assert rule.get('type') in ('DOMAIN', 'DOMAIN-SUFFIX')
        value = rule.get('value', '')
        assert domain_re.fullmatch(value) or (rule.get('type') == 'DOMAIN-SUFFIX' and tld_re.fullmatch(value))
        assert rule.get('policy') == 'DIRECT'
        key = (rule['type'], rule['value'])
        assert key not in seen_rules
        seen_rules.add(key)
    for route in routes:
        ip = str(ipaddress.IPv4Address(route.get('ipv4')))
        assert ip not in seen_ips
        seen_ips.add(ip)
        assert type(route.get('include_www')) is bool
        assert type(route.get('enabled')) is bool
        assert isinstance(route.get('domains'), list)
        for domain in route['domains']:
            assert domain_re.fullmatch(domain) and domain not in seen_domains
            seen_domains.add(domain)
except Exception:
    raise SystemExit(1)
PY
}

render_stash_rules() {
  python3 - "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
for rule in data['rules']:
    print(f"{rule['type']},{rule['value']},{rule['policy']}")
PY
}

render_hosts_block() {
  python3 - "$1" "$2" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
print('# BEGIN LANPRO DIRECT ROUTING')
for route in data['fixed_routes']:
    if not route['enabled']:
        continue
    for domain in route['domains']:
        print(route['ipv4'], domain)
        if route['include_www'] and not domain.startswith('www.'):
            print(route['ipv4'], 'www.' + domain)
seen = set()
with open(sys.argv[2], encoding='utf-8') as resolved:
    for line in resolved:
        parts = line.rstrip('\n').split('\t')
        if len(parts) == 2 and parts[0] not in seen:
            print(parts[1], parts[0])
            seen.add(parts[0])
print('# END LANPRO DIRECT ROUTING')
PY
}

render_route_commands() {
  config=$1 gateway=$2 resolved=${3:-}
  python3 - "$config" "$gateway" "$resolved" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
ips = {route['ipv4'] for route in data['fixed_routes'] if route['enabled']}
ips.update(ip for ip in sys.argv[3].split() if ip)
for ip in sorted(ips):
    print(f"route -n add -host {ip} {sys.argv[2]}")
PY
}

replace_managed_hosts() {
  existing=$1 block=$2
  printf '%s\n' "$existing" | awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    $0 == begin {managed=1; next}
    $0 == end {managed=0; next}
    !managed {print}
  ' | sed -e ':a' -e '/^[[:space:]]*$/{$d;N;ba' -e '}'
  printf '%s\n' "$block"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || { echo 'Run this command with sudo.' >&2; exit 1; }
}

physical_gateway() {
  if command -v networksetup >/dev/null 2>&1 && command -v ipconfig >/dev/null 2>&1; then
    networksetup -listallhardwareports | awk '/Device:/{print $2}' | while IFS= read -r iface; do
      case "$iface" in lo*|utun*|ipsec*|gif*|stf*) continue ;; esac
      gateway=$(ipconfig getoption "$iface" router 2>/dev/null || true)
      if [ -n "$gateway" ]; then printf '%s\t%s\n' "$gateway" "$iface"; break; fi
    done
  else
    route -n get default 2>/dev/null | awk '/gateway:/{gateway=$2}/interface:/{iface=$2}END{if(gateway)print gateway "\t" iface}'
  fi
}

fetch_config() {
  mkdir -p "$STATE_DIR"
  temp="$STATE_DIR/direct-sites.json.tmp.$$"
  if curl -fsSL --connect-timeout 15 --max-time 30 "$CONFIG_URL" -o "$temp" && validate_config "$temp"; then
    mv -f "$temp" "$STATE_DIR/direct-sites.json"
  else
    rm -f "$temp"
    echo 'Warning: central config unavailable or invalid; using last valid cache.' >&2
  fi
  validate_config "$STATE_DIR/direct-sites.json" || { echo 'No valid cached configuration.' >&2; exit 1; }
  printf '%s\n' "$STATE_DIR/direct-sites.json"
}

resolve_public_ipv4() {
  domain=$1
  if command -v dig >/dev/null 2>&1; then
    dig +short A "$domain" @1.1.1.1 2>/dev/null | awk '/^[0-9]+(\.[0-9]+){3}$/' | sort -u
  else
    dscacheutil -q host -a name "$domain" 2>/dev/null | awk '/ip_address:/{print $2}' | awk '/^[0-9]+(\.[0-9]+){3}$/' | sort -u
  fi
}

resolve_rule_targets() {
  config=$1 output=$2
  : > "$output"
  python3 - "$config" <<'PY' | while IFS='\t' read -r type domain; do
import json, sys
for rule in json.load(open(sys.argv[1], encoding='utf-8'))['rules']:
    print(rule['type'] + '\t' + rule['value'])
PY
    case "$domain" in *.*) ;; *) continue ;; esac
    resolve_public_ipv4 "$domain" | while IFS= read -r ip; do printf '%s\t%s\n' "$domain" "$ip" >> "$output"; done
    if [ "$type" = 'DOMAIN-SUFFIX' ]; then
      resolve_public_ipv4 "www.$domain" | while IFS= read -r ip; do printf '%s\t%s\n' "www.$domain" "$ip" >> "$output"; done
    fi
  done
}

sync_routes() {
  require_root
  config=$(fetch_config)
  gateway_info=$(physical_gateway)
  [ -n "$gateway_info" ] || { echo 'Physical gateway was not found.' >&2; exit 1; }
  gateway=$(printf '%s' "$gateway_info" | cut -f1)
  iface=$(printf '%s' "$gateway_info" | cut -f2)
  resolved="$STATE_DIR/resolved.tsv"
  resolve_rule_targets "$config" "$resolved"
  resolved_ips=$(cut -f2 "$resolved" | sort -u | tr '\n' ' ')
  new_ips=$(python3 - "$config" <<'PY'
import json, sys
for route in json.load(open(sys.argv[1], encoding='utf-8'))['fixed_routes']:
    if route['enabled']: print(route['ipv4'])
PY
  printf '%s\n' $resolved_ips) 
  new_ips=$(printf '%s\n' "$new_ips" | awk 'NF' | sort -u)
  old_ips=''
  [ ! -f "$STATE_DIR/managed-ips.txt" ] || old_ips=$(cat "$STATE_DIR/managed-ips.txt")

  if [ "${DIRECT_ROUTING_DRY_RUN:-0}" = 1 ]; then
    echo "Physical gateway: $gateway ($iface)"
    render_route_commands "$config" "$gateway" "$resolved_ips"
    return
  fi

  printf '%s\n' "$old_ips" | while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    printf '%s\n' "$new_ips" | grep -Fx "$ip" >/dev/null || route -n delete -host "$ip" >/dev/null 2>&1 || true
  done
  printf '%s\n' "$new_ips" | while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    route -n add -host "$ip" "$gateway" >/dev/null 2>&1 || route -n change -host "$ip" "$gateway" >/dev/null
  done
  hosts_block=$(render_hosts_block "$config" "$resolved")
  existing=$(cat "$HOSTS_PATH" 2>/dev/null || true)
  temp_hosts="$STATE_DIR/hosts.tmp.$$"
  replace_managed_hosts "$existing" "$hosts_block" > "$temp_hosts"
  cat "$temp_hosts" > "$HOSTS_PATH"
  rm -f "$temp_hosts"
  printf '%s\n' "$new_ips" > "$STATE_DIR/managed-ips.txt"
  printf 'synced_at=%s\ngateway=%s\ninterface=%s\nips=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$gateway" "$iface" "$(printf '%s\n' "$new_ips" | wc -l | tr -d ' ')" > "$STATE_DIR/status"
  dscacheutil -flushcache 2>/dev/null || true
  killall -HUP mDNSResponder 2>/dev/null || true
  echo "Direct routing synchronized through $gateway ($iface)."
}

install_client() {
  require_root
  mkdir -p "$STATE_DIR"
  cp "$0" "$STATE_DIR/direct-sites.sh"
  chmod 755 "$STATE_DIR/direct-sites.sh"
  cat > /Library/LaunchDaemons/uz.lanpro.direct-routing.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>uz.lanpro.direct-routing</string>
<key>ProgramArguments</key><array><string>$STATE_DIR/direct-sites.sh</string><string>sync</string></array>
<key>RunAtLoad</key><true/><key>StartInterval</key><integer>1800</integer>
<key>StandardOutPath</key><string>$STATE_DIR/direct-routing.log</string>
<key>StandardErrorPath</key><string>$STATE_DIR/direct-routing-error.log</string>
</dict></plist>
PLIST
  chown root:wheel /Library/LaunchDaemons/uz.lanpro.direct-routing.plist
  launchctl bootout system/uz.lanpro.direct-routing >/dev/null 2>&1 || true
  launchctl bootstrap system /Library/LaunchDaemons/uz.lanpro.direct-routing.plist
  sync_routes
}

uninstall_client() {
  require_root
  launchctl bootout system/uz.lanpro.direct-routing >/dev/null 2>&1 || true
  rm -f /Library/LaunchDaemons/uz.lanpro.direct-routing.plist
  if [ -f "$STATE_DIR/managed-ips.txt" ]; then
    while IFS= read -r ip; do [ -z "$ip" ] || route -n delete -host "$ip" >/dev/null 2>&1 || true; done < "$STATE_DIR/managed-ips.txt"
  fi
  existing=$(cat "$HOSTS_PATH" 2>/dev/null || true)
  replace_managed_hosts "$existing" '' > "$STATE_DIR/hosts.clean"
  awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '$0 != begin && $0 != end' "$STATE_DIR/hosts.clean" > "$HOSTS_PATH"
  rm -rf "$STATE_DIR"
  echo 'LANPRO Direct Routing removed.'
}

show_status() {
  [ -f "$STATE_DIR/status" ] && cat "$STATE_DIR/status" || echo 'Not installed or not synchronized.'
}

test_target() {
  [ -n "$TARGET" ] || { echo 'Provide a domain after test.' >&2; exit 1; }
  resolve_public_ipv4 "$TARGET" | sed 's/^/Public IPv4: /'
  curl -4 -I -L --connect-timeout 10 "https://$TARGET/"
}

if [ "${DIRECT_ROUTING_LIB_ONLY:-0}" != 1 ]; then
  case "$COMMAND" in
    install) install_client ;;
    sync) sync_routes ;;
    status) show_status ;;
    test) test_target ;;
    rules) config=$(fetch_config); render_stash_rules "$config" ;;
    uninstall) uninstall_client ;;
    *) echo 'Usage: direct-sites.sh {install|sync|status|test DOMAIN|rules|uninstall}' >&2; exit 2 ;;
  esac
fi
