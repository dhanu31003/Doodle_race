#!/bin/sh
set -eu

domain="${RACEGLYPH_DOMAIN:-multiplayer.neutale.com}"
case "${domain}" in
  *[!A-Za-z0-9.-]*|.*|*..*|*.)
    echo "RACEGLYPH_DOMAIN is invalid." >&2
    exit 2
    ;;
esac

curl --fail --silent --show-error \
  --connect-timeout 5 \
  --max-time 10 \
  "https://${domain}/healthcheck" >/dev/null

echo "RaceGlyph public Nakama healthcheck passed over TLS."
