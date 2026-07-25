#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(unset CDPATH; cd -- "${script_dir}/../.." && pwd)
godot_bin="${GODOT_BIN:-godot}"
log_file=$(mktemp "${TMPDIR:-/tmp}/raceglyph-nakama-12-client.XXXXXX")
godot_args=(--headless --path "${project_dir}" --max-fps 60 --quit-after 7200)
if [[ "${RACEGLYPH_GODOT_VERBOSE:-0}" == "1" ]]; then
  godot_args+=(--verbose)
fi

# Invoked by the signal/exit trap below.
# shellcheck disable=SC2329
cleanup() {
  rm -f "${log_file}"
}
trap cleanup EXIT HUP INT TERM

if [[ "${RACEGLYPH_TEST_NAKAMA_PORT:-}" == "" ]]; then
  echo "RACEGLYPH_TEST_NAKAMA_PORT is required by the local-only load runner." >&2
  exit 2
fi
if [[ ! "${RACEGLYPH_TEST_NAKAMA_PORT}" =~ ^[0-9]+$ ]] ||
    ((RACEGLYPH_TEST_NAKAMA_PORT < 1024 || RACEGLYPH_TEST_NAKAMA_PORT > 65535)); then
  echo "RACEGLYPH_TEST_NAKAMA_PORT must be a non-privileged local TCP port." >&2
  exit 2
fi

set +e
"${godot_bin}" "${godot_args[@]}" res://tests/network/nakama_12_client_load.tscn \
  >"${log_file}" 2>&1
engine_status=$?
set -e

cat "${log_file}"
if grep -E 'SCRIPT ERROR|Parse Error|Failed to load script|Invalid call|Stack overflow|^ERROR:|^WARNING:' \
    "${log_file}" >/dev/null 2>&1; then
  echo "12-client wrapper detected a Godot parse/runtime/error/leak diagnostic." >&2
  exit 1
fi
if ! grep -F 'PASS nakama_real_12_client_load' "${log_file}" >/dev/null 2>&1; then
  echo "12-client load smoke did not reach its passing terminal assertion." >&2
  exit 1
fi
if ! grep -E '^LOAD_METRICS protocol=2 clients=12 authentications=13 admissions=12 overflow_refusals=1 input_relayed=55 snapshot_deliveries=33 elapsed_ms=[0-9]+$' \
    "${log_file}" >/dev/null 2>&1; then
  echo "12-client load smoke emitted incomplete relay metrics." >&2
  exit 1
fi
exit "${engine_status}"
