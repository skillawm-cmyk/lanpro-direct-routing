#!/bin/sh
set -eu

[ "$(id -u)" -eq 0 ] || { echo 'Run with sudo.' >&2; exit 1; }
URL='https://raw.githubusercontent.com/skillawm-cmyk/lanpro-direct-routing/main/macos/direct-sites.sh'
TEMP=$(mktemp /tmp/lanpro-direct-sites.XXXXXX)
trap 'rm -f "$TEMP"' EXIT
curl -fsSL --connect-timeout 15 --max-time 60 "$URL" -o "$TEMP"
chmod 755 "$TEMP"
"$TEMP" install
