#!/bin/sh
set -eu

api_port="${NAKAMA_API_PORT:-7350}"
health_url="http://127.0.0.1:${api_port}/healthcheck"

curl --fail --silent --show-error \
  --connect-timeout 2 \
  --max-time 5 \
  "${health_url}" >/dev/null

echo "RaceGlyph local Nakama healthcheck passed at ${health_url}"

