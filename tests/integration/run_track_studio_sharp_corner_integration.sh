#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GODOT_EXECUTABLE="${GODOT_BIN:-godot}"
TEST_LOG="$(mktemp -t track-studio-sharp-corner.XXXXXX)"
trap 'rm -f "${TEST_LOG}"' EXIT

set +e
"${GODOT_EXECUTABLE}" --headless --path "${PROJECT_DIR}" \
  --script res://tests/integration/run_track_studio_sharp_corner_integration.gd 2>&1 | tee "${TEST_LOG}"
GODOT_STATUS=${PIPESTATUS[0]}
set -e

if grep -Eq 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script' "${TEST_LOG}"; then
  exit 1
fi
exit "${GODOT_STATUS}"
