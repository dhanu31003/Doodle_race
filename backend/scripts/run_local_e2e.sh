#!/bin/sh
set -eu

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
backend_dir=$(unset CDPATH; cd -- "${script_dir}/.." && pwd)
project_dir=$(unset CDPATH; cd -- "${backend_dir}/.." && pwd)
compose_project="raceglyph-e2e-$$"

find_free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

if command -v docker-compose >/dev/null 2>&1; then
  compose_command="docker-compose"
elif docker compose version >/dev/null 2>&1; then
  compose_command="docker compose"
else
  echo "Docker Compose is unavailable." >&2
  exit 1
fi

NAKAMA_API_PORT="${NAKAMA_API_PORT:-$(find_free_port)}"
NAKAMA_CONSOLE_PORT="${NAKAMA_CONSOLE_PORT:-$(find_free_port)}"
while [ "${NAKAMA_API_PORT}" = "${NAKAMA_CONSOLE_PORT}" ]; do
  NAKAMA_CONSOLE_PORT=$(find_free_port)
done
export NAKAMA_API_PORT NAKAMA_CONSOLE_PORT

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

"${backend_dir}/scripts/healthcheck.sh"
RACEGLYPH_TEST_NAKAMA_PORT="${NAKAMA_API_PORT}" \
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
