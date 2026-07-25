#!/bin/sh
set -eu

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
backend_dir=$(unset CDPATH; cd -- "${script_dir}/.." && pwd)
project_dir=$(unset CDPATH; cd -- "${backend_dir}/.." && pwd)
compose_project="raceglyph-e2e"

if command -v docker-compose >/dev/null 2>&1; then
  compose_command="docker-compose"
elif docker compose version >/dev/null 2>&1; then
  compose_command="docker compose"
else
  echo "Docker Compose is unavailable." >&2
  exit 1
fi

cleanup() {
  # shellcheck disable=SC2086
  ${compose_command} -p "${compose_project}" --env-file "${backend_dir}/.env.example" \
    -f "${backend_dir}/compose.yaml" down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM
cleanup

# shellcheck disable=SC2086
${compose_command} -p "${compose_project}" --env-file "${backend_dir}/.env.example" \
  -f "${backend_dir}/compose.yaml" up -d --wait

NAKAMA_API_PORT=7350 "${backend_dir}/scripts/healthcheck.sh"
"${project_dir}/tests/network/run_nakama_e2e.sh"

# Fail on backend panics/fatals or runtime JavaScript errors.
# shellcheck disable=SC2086
if ${compose_command} -p "${compose_project}" --env-file "${backend_dir}/.env.example" \
    -f "${backend_dir}/compose.yaml" logs --no-color nakama | \
    grep -E '"level":"(panic|fatal)"|JavaScript.*(error|exception)' >/dev/null 2>&1; then
  echo "Nakama emitted a fatal/runtime error during E2E." >&2
  exit 1
fi

echo "RaceGlyph real Nakama E2E passed."

