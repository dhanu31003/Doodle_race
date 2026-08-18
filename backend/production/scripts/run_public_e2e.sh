#!/bin/sh
set -eu

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
production_dir=$(unset CDPATH; cd -- "${script_dir}/.." && pwd)
project_dir=$(unset CDPATH; cd -- "${production_dir}/../.." && pwd)
domain="${RACEGLYPH_PUBLIC_HOST:-multiplayer.neutale.com}"

if [ "${domain}" != "multiplayer.neutale.com" ]; then
  echo "Public smoke hostname must match the mobile release client." >&2
  exit 2
fi

RACEGLYPH_DOMAIN="${domain}" "${script_dir}/healthcheck.sh"

RACEGLYPH_TEST_NAKAMA_HOST="${domain}" \
RACEGLYPH_TEST_NAKAMA_PORT=443 \
RACEGLYPH_TEST_NAKAMA_SCHEME=https \
RACEGLYPH_TEST_NAKAMA_KEY=raceglyph_mobile_protocol_4 \
  "${project_dir}/tests/network/run_nakama_e2e.sh"

echo "RaceGlyph public HTTPS/WSS room, relay, reconnect, and result smoke passed."
