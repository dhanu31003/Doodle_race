#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GODOT_EXECUTABLE="${GODOT_BIN:-godot}"
TEST_LOG="$(mktemp -t raceglyph-accessibility-layout.XXXXXX)"
trap 'rm -f "${TEST_LOG}"' EXIT

set +e
"${GODOT_EXECUTABLE}" --headless --path "${PROJECT_DIR}" \
  --script res://tests/ui/run_accessibility_layout_test.gd 2>&1 | tee -a "${TEST_LOG}"
GODOT_STATUS=${PIPESTATUS[0]}
set -e

if grep -Eq 'LAYOUT_AUDIT FAIL|SCRIPT ERROR|Parse Error|Compile Error|Failed to load script|Invalid call|Invalid assignment|resources still in use|ObjectDB instances were leaked' "${TEST_LOG}"; then
  echo "Accessibility layout test detected an overflow or runtime/resource error." >&2
  exit 1
fi

PASS_COUNT=$(grep -c 'LAYOUT_AUDIT PASS' "${TEST_LOG}" || true)
EXPECTED_COUNT=26
if [[ ${GODOT_STATUS} -ne 0 || ${PASS_COUNT} -ne ${EXPECTED_COUNT} ]]; then
  echo "Accessibility layout test did not complete all ${EXPECTED_COUNT} fixtures." >&2
  exit 1
fi
