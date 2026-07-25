#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GODOT_EXECUTABLE="${GODOT_BIN:-godot}"
LOG_PATH="$(mktemp -t raceglyph-builtin-track-performance.XXXXXX)"
trap 'rm -f "${LOG_PATH}"' EXIT

set +e
"${GODOT_EXECUTABLE}" --headless --path "${PROJECT_DIR}" \
  --script res://tests/performance/run_predefined_track_catalog_benchmark.gd \
  2>&1 | tee "${LOG_PATH}"
GODOT_STATUS=${PIPESTATUS[0]}
set -e

if grep -Eq 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script|Invalid call|Stack overflow' "${LOG_PATH}"; then
  echo "Built-in track performance wrapper detected a Godot script/runtime error." >&2
  exit 1
fi
exit "${GODOT_STATUS}"
