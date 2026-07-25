#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
backend_dir=$(unset CDPATH; cd -- "${script_dir}/.." && pwd)
project_dir=$(unset CDPATH; cd -- "${backend_dir}/.." && pwd)
compose_project="raceglyph-load-${RANDOM}-$$"
env_file="${backend_dir}/.env.example"
compose_file="${backend_dir}/compose.yaml"
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/raceglyph-load-stack.XXXXXX")
test_log="${temp_dir}/test.log"
backend_log="${temp_dir}/backend.log"
evidence_dir="${project_dir}/evidence/logs"
compose_command=()

find_free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

compose() {
  "${compose_command[@]}" -p "${compose_project}" --env-file "${env_file}" -f "${compose_file}" "$@"
}

cleanup() {
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf "${temp_dir}"
}
trap cleanup EXIT HUP INT TERM

if docker compose version >/dev/null 2>&1; then
  compose_command=(docker compose)
elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
  compose_command=(docker-compose)
else
  echo "A Compose v2-compatible Docker CLI is required for the isolated 12-client load smoke." >&2
  exit 2
fi

export NAKAMA_API_PORT="${NAKAMA_API_PORT:-$(find_free_port)}"
export NAKAMA_CONSOLE_PORT="${NAKAMA_CONSOLE_PORT:-$(find_free_port)}"
if [[ "${NAKAMA_API_PORT}" == "${NAKAMA_CONSOLE_PORT}" ]]; then
  echo "Disposable Nakama API and console ports must differ." >&2
  exit 2
fi

compose down --volumes --remove-orphans >/dev/null 2>&1 || true
if ! compose up -d --wait >"${temp_dir}/compose-up.log" 2>&1; then
  echo "Disposable Nakama load stack did not become ready." >&2
  exit 1
fi

set +e
RACEGLYPH_TEST_NAKAMA_PORT="${NAKAMA_API_PORT}" \
  "${project_dir}/tests/network/run_nakama_12_client_load.sh" >"${test_log}" 2>&1
test_status=$?
set -e

compose logs --no-color nakama >"${backend_log}" 2>&1
if grep -E '"level":"(panic|fatal|error)"|JavaScript[^[:cntrl:]]*(error|exception)' \
    "${backend_log}" >/dev/null 2>&1; then
  echo "Nakama emitted a structured fatal/runtime error during 12-client load." >&2
  exit 1
fi
if grep -F -e 'CHANGE_ME_LOCAL_POSTGRES_32_CHARS' \
    -e 'CHANGE_ME_LOCAL_SERVER_KEY_32_CHARS' \
    -e 'CHANGE_ME_LOCAL_SESSION_KEY_32_CHARS' \
    -e 'CHANGE_ME_LOCAL_REFRESH_KEY_32_CHARS' \
    -e 'CHANGE_ME_LOCAL_RUNTIME_KEY_32_CHARS' \
    -e 'CHANGE_ME_LOCAL_CONSOLE_PASSWORD' \
    -e 'CHANGE_ME_LOCAL_CONSOLE_SIGNING_32_CHARS' \
    "${backend_log}" "${test_log}" >/dev/null 2>&1; then
  echo "Local load logs exposed a disposable credential; evidence was not retained." >&2
  exit 1
fi
if grep -E 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}' \
    "${backend_log}" "${test_log}" >/dev/null 2>&1; then
  echo "Local load logs exposed a session-like token; evidence was not retained." >&2
  exit 1
fi
if ((test_status != 0)); then
  cat "${test_log}"
  exit "${test_status}"
fi

mkdir -p "${evidence_dir}"
timestamp=$(date -u +'%Y%m%dT%H%M%SZ')
evidence_log="${evidence_dir}/nakama-12-client-load-${timestamp}.log"
{
  cat "${test_log}"
  echo "LOAD_DIAGNOSTICS godot_errors=0 godot_warnings=0 objectdb_leaks=0 resource_leaks=0 backend_errors=0 secret_hits=0 token_hits=0"
} >"${evidence_log}"
sha256sum "${evidence_log}" >"${evidence_log}.sha256"
cat "${evidence_log}"
echo "LOAD_EVIDENCE path=${evidence_log} sha256=$(cut -d ' ' -f 1 "${evidence_log}.sha256")"
