#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GODOT_EXECUTABLE="${GODOT_BIN:-godot}"
TEST_LOG="$(mktemp -t raceglyph-race-hud.XXXXXX)"
trap 'rm -f "${TEST_LOG}"' EXIT

set +e
"${GODOT_EXECUTABLE}" --headless --path "${PROJECT_DIR}" \
  --script res://tests/ui/run_race_hud_components_test.gd 2>&1 | tee "${TEST_LOG}"
GODOT_STATUS=${PIPESTATUS[0]}
set -e

if [[ ${GODOT_STATUS} -ne 0 ]] || ! grep -q 'PASS race_hud_components' "${TEST_LOG}"; then
  echo "Race HUD component test did not pass." >&2
  exit 1
fi
if grep -Eq 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script|ERROR:|ObjectDB instances were leaked|resources still in use' "${TEST_LOG}"; then
  echo "Race HUD component test reported a runtime/resource error." >&2
  exit 1
fi
