#!/bin/sh
set -u

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(unset CDPATH; cd -- "${script_dir}/../.." && pwd)
godot_bin="${GODOT_BIN:-godot}"
log_file=$(mktemp "${TMPDIR:-/tmp}/raceglyph-nakama-e2e.XXXXXX")
trap 'rm -f "${log_file}"' EXIT HUP INT TERM

set +e
"${godot_bin}" --headless --path "${project_dir}" \
  --script res://tests/network/run_nakama_e2e.gd --check-only >"${log_file}" 2>&1
parse_status=$?
if [ "${parse_status}" -ne 0 ] || \
    grep -E 'SCRIPT ERROR|Parse Error|Failed to load script|Invalid call|Stack overflow|^(ERROR|WARNING):' \
      "${log_file}" >/dev/null 2>&1; then
  set -e
  cat "${log_file}"
  echo "Nakama E2E preflight detected a Godot warning, error, or parse failure." >&2
  exit 1
fi

"${godot_bin}" --headless --path "${project_dir}" \
  --max-fps 60 --quit-after 3600 \
  --script res://tests/network/run_nakama_e2e.gd >"${log_file}" 2>&1
engine_status=$?
set -e

cat "${log_file}"
if grep -E "SCRIPT ERROR|Parse Error|Failed to load script|Invalid call|Stack overflow" "${log_file}" >/dev/null 2>&1; then
  echo "Nakama E2E wrapper detected a Godot script/runtime error." >&2
  exit 1
fi
if grep -E '^(ERROR|WARNING):' "${log_file}" >/dev/null 2>&1; then
  echo "Nakama E2E wrapper detected a Godot warning or error." >&2
  exit 1
fi
if ! grep -F "PASS nakama_real_backend_e2e" "${log_file}" >/dev/null 2>&1; then
  echo "Nakama E2E did not reach its passing terminal assertion." >&2
  exit 1
fi
exit "${engine_status}"
