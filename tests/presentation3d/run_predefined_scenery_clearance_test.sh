#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GODOT_EXECUTABLE="${GODOT_BIN:-godot}"
LOG_PATH="$(mktemp -t raceglyph-catalog-scenery-clearance.XXXXXX)"
trap 'rm -f "${LOG_PATH}"' EXIT

set +e
"${GODOT_EXECUTABLE}" --headless --path "${PROJECT_DIR}" \
  --script res://tests/presentation3d/run_predefined_scenery_clearance_test.gd \
  2>&1 | tee "${LOG_PATH}"
GODOT_STATUS=${PIPESTATUS[0]}
set -e

if grep -Eq 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script|Invalid call|Stack overflow|ObjectDB instances were leaked|resources still in use' "${LOG_PATH}"; then
  echo "Predefined scenery clearance wrapper detected a Godot/runtime error." >&2
  exit 1
fi
exit "${GODOT_STATUS}"
