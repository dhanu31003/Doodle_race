#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GODOT_EXECUTABLE="${GODOT_BIN:-godot}"
SMOKE_LOG="$(mktemp -t raceglyph-predefined-ai-smoke.XXXXXX)"
trap 'rm -f "${SMOKE_LOG}"' EXIT

set +e
RACE_SOAK_TARGET=predefined_catalog_smoke \
  "${GODOT_EXECUTABLE}" --headless --path "${PROJECT_DIR}" \
  --script res://tests/race/run_ai_soak.gd 2>&1 | tee "${SMOKE_LOG}"
GODOT_STATUS=${PIPESTATUS[0]}
set -e

if grep -Eq 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script|Invalid call|Stack overflow' "${SMOKE_LOG}"; then
  echo "Predefined AI smoke wrapper detected a Godot script/runtime error." >&2
  exit 1
fi
exit "${GODOT_STATUS}"
