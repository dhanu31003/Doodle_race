#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GODOT_EXECUTABLE="${GODOT_BIN:-godot}"
TEST_LOG="$(mktemp -t raceglyph-race-world-3d.XXXXXX)"
trap 'rm -f "${TEST_LOG}"' EXIT

set +e
"${GODOT_EXECUTABLE}" --headless --path "${PROJECT_DIR}" \
  --quit-after 300 \
  --script res://tests/presentation3d/run_race_world_3d_integration_test.gd 2>&1 \
  | tee "${TEST_LOG}"
GODOT_STATUS=${PIPESTATUS[0]}
set -e

if grep -Eq 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script|Invalid call|Stack overflow|^ERROR:|resources still in use|ObjectDB instances were leaked' "${TEST_LOG}"; then
  echo "RaceWorld3D integration test detected a Godot script/runtime/resource error." >&2
  exit 1
fi
exit "${GODOT_STATUS}"
