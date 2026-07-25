#!/bin/sh
set -eu

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
backend_dir=$(unset CDPATH; cd -- "${script_dir}/.." && pwd)

if command -v docker-compose >/dev/null 2>&1; then
  compose_command="docker-compose"
elif docker compose version >/dev/null 2>&1; then
  compose_command="docker compose"
else
  echo "Docker Compose is unavailable." >&2
  exit 1
fi

# shellcheck disable=SC2086
${compose_command} \
  --env-file "${backend_dir}/.env.example" \
  -f "${backend_dir}/compose.yaml" \
  config --quiet

echo "RaceGlyph local backend compose configuration is valid."
