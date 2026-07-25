#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GODOT_EXECUTABLE="${GODOT_BIN:-godot}"
TEST_LOG="$(mktemp -t raceglyph-ui-smoke.XXXXXX)"
trap 'rm -f "${TEST_LOG}"' EXIT

ROUTES=(splash home studio tracks tour race_config race network_race saved garage settings credits multiplayer)
FAILED=0

for route in "${ROUTES[@]}"; do
  echo "UI route: ${route}"
  set +e
  "${GODOT_EXECUTABLE}" --headless --path "${PROJECT_DIR}" -- \
    "--route=${route}" --smoke-frames=4 2>&1 | tee -a "${TEST_LOG}"
  GODOT_STATUS=${PIPESTATUS[0]}
  set -e
  if [[ ${GODOT_STATUS} -ne 0 ]]; then
    FAILED=1
  fi
done

if grep -Eq 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script|Invalid call|Invalid assignment|resources still in use|ObjectDB instances were leaked' "${TEST_LOG}"; then
  echo "UI smoke detected a Godot script/runtime/resource error." >&2
  exit 1
fi

if [[ ${FAILED} -ne 0 ]]; then
  echo "UI smoke detected a non-zero route exit." >&2
  exit 1
fi

echo "PASS UI route smoke (${#ROUTES[@]} routes, clean shutdown)"
