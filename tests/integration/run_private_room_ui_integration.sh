#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GODOT_EXECUTABLE="${GODOT_BIN:-godot}"
TEST_LOG="$(mktemp -t raceglyph-private-room-ui.XXXXXX)"
trap 'rm -f "${TEST_LOG}"' EXIT

set +e
"${GODOT_EXECUTABLE}" --headless --path "${PROJECT_DIR}" \
  --quit-after 900 \
  --script res://tests/integration/run_private_room_ui_integration.gd 2>&1 \
  | tee "${TEST_LOG}"
GODOT_STATUS=${PIPESTATUS[0]}
set -e

if grep -Eq 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script|Invalid call|Stack overflow|^ERROR:|resources still in use|ObjectDB instances were leaked' "${TEST_LOG}"; then
  echo "Private-room UI integration detected a Godot script/runtime/resource error." >&2
  exit 1
fi
exit "${GODOT_STATUS}"
