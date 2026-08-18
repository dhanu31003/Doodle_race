#!/bin/sh
set -eu

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
production_dir=$(unset CDPATH; cd -- "${script_dir}/.." && pwd)

if command -v docker-compose >/dev/null 2>&1; then
  compose_command="docker-compose"
elif docker compose version >/dev/null 2>&1; then
  compose_command="docker compose"
else
  echo "Docker Compose is unavailable." >&2
  exit 1
fi

config_json=$(mktemp "${TMPDIR:-/tmp}/raceglyph-production-compose.XXXXXX")
cleanup() {
  rm -f "${config_json}"
}
trap cleanup EXIT HUP INT TERM

# shellcheck disable=SC2086
${compose_command} --env-file "${production_dir}/.env.example" \
  -f "${production_dir}/compose.yaml" config --format json >"${config_json}"

python3 - "${config_json}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
services = config["services"]
assert not services["postgres"].get("ports"), "PostgreSQL must not publish a host port"
assert not services["nakama"].get("ports"), "Nakama must be reachable only through TLS ingress"
published = {
    (int(item["published"]), item["protocol"])
    for item in services["caddy"].get("ports", [])
}
assert published == {(80, "tcp"), (443, "tcp"), (443, "udp")}, published
assert services["nakama"]["networks"] == {"backend": None}
assert config["networks"]["backend"].get("internal") is True
print("PASS production topology exposes only HTTP/HTTPS ingress")
PY

echo "RaceGlyph production backend compose configuration is valid."
