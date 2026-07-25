#!/bin/sh
set -u

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(unset CDPATH; cd -- "${script_dir}/../.." && pwd)
godot_bin="${GODOT_BIN:-godot}"
log_file=$(mktemp "${TMPDIR:-/tmp}/raceglyph-network-tests.XXXXXX")
trap 'rm -f "${log_file}"' EXIT HUP INT TERM

set +e
"${godot_bin}" --headless --path "${project_dir}" \
  --script res://tests/network/run_network_tests.gd >"${log_file}" 2>&1
engine_status=$?
set -e

cat "${log_file}"

if grep -E "SCRIPT ERROR|Parse Error|Failed to load script|Invalid call|Stack overflow" "${log_file}" >/dev/null 2>&1; then
  echo "Network test wrapper detected a Godot script/runtime error." >&2
  exit 1
fi

exit "${engine_status}"
