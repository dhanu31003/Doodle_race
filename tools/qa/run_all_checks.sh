#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
EVIDENCE_DIR="${PROJECT_DIR}/evidence/logs"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_PATH="${EVIDENCE_DIR}/full-check-${STAMP}.log"
WITH_BACKEND=0
WITH_SOAK=0
WITH_BACKEND_OPS=0
ALL_CHECKS_COMPLETE=0

case "${1:-}" in
  "") ;;
  --with-backend)
    WITH_BACKEND=1
    ;;
  --release)
    WITH_BACKEND=1
    WITH_SOAK=1
    WITH_BACKEND_OPS=1
    ;;
  *)
    echo "Usage: $0 [--with-backend|--release]" >&2
    exit 64
    ;;
esac

mkdir -p "${EVIDENCE_DIR}"
exec 3>&1 4>&2
exec > >(tee "${LOG_PATH}") 2>&1
TEE_PID=$!
cd "${PROJECT_DIR}"

finalize() {
  local status=$?
  trap - EXIT
  # A terminal/runner interruption can leave Bash with a zero EXIT status even
  # though the foreground child was stopped.  A release log is authoritative
  # only after control reaches the explicit completion marker below.
  if [[ ${status} -eq 0 && ${ALL_CHECKS_COMPLETE} -ne 1 ]]; then
    echo "FAIL verification stopped before every requested check completed"
    status=1
  fi
  if [[ ${status} -eq 0 ]] && grep -Eq \
      'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script|ERROR:|ObjectDB instances were leaked|resources still in use' \
      "${LOG_PATH}"; then
    echo "FAIL verification log contains a Godot/runtime error"
    status=1
  fi
  if [[ ${status} -eq 0 ]]; then
    echo "PASS all requested checks"
  else
    echo "FAIL one or more requested checks"
  fi
  echo "Evidence ${LOG_PATH}"
  exec 1>&3 2>&4
  # Some launchers re-parent Bash process substitutions before the EXIT trap.
  # The output descriptor is already closed above, so a failed wait is benign.
  wait "${TEE_PID}" 2>/dev/null || true
  shasum -a 256 "${LOG_PATH}" > "${LOG_PATH}.sha256"
  echo "Checksum ${LOG_PATH}.sha256"
  exit "${status}"
}
trap finalize EXIT

run_case() {
  local label="$1"
  shift
  echo "CHECK ${label}"
  "$@"
}

echo "RaceGlyph full verification"
echo "UTC ${STAMP}"
echo "Git commit $(git rev-parse HEAD 2>/dev/null || echo unavailable)"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  echo "Git tree dirty"
else
  echo "Git tree clean"
fi
godot --version

run_case "asset inventory" python3 tools/asset_validation/validate_svg_assets.py
run_case "release source contracts" tools/qa/verify_release_contracts.sh
run_case "editor parse" godot --headless --editor --path . --quit
run_case "track domain" tests/support/run_track_domain_tests.sh
run_case "maximum-size track smoothing performance" tests/performance/run_track_smoothing_benchmark.sh
run_case "built-in track mobile geometry performance" tests/performance/run_predefined_track_catalog_benchmark.sh
run_case "track runtime" tests/support/run_track_runtime_integration.sh
run_case "Track Studio automatic corner recovery" tests/integration/run_track_studio_sharp_corner_integration.sh
run_case "track world features" tests/track_features/run_track_feature_tests.sh
run_case "track world presentation" tests/track_rendering/run_track_world_render_tests.sh
run_case "true 3D track mesh" tests/presentation3d/run_presentation_3d_tests.sh
run_case "true 3D Formula car" tests/presentation3d/run_formula_car_visual_3d_test.sh
run_case "fixed-distance 3D camera rig" tests/presentation3d/run_camera_rig_3d_test.sh
run_case "bounded 3D collision sparks" tests/presentation3d/run_collision_spark_pool_3d_test.sh
run_case "true 3D fixed race world" tests/presentation3d/run_race_world_3d_integration.sh
run_case "all default-circuit 3D scenery clearance" tests/presentation3d/run_predefined_scenery_clearance_test.sh
run_case "content and safe areas" tests/content/run_content_tests.sh
run_case "persistence and settings" tests/unit/run_persistence_settings_tests.sh
run_case "audio" tools/audio/run_audio_checks.sh
run_case "mobile race telemetry and standings" tests/ui/run_race_hud_components_test.sh
run_case "race authority and AI" tests/race/run_race_tests.sh
run_case "all default-circuit twelve-car AI finish smoke" tests/race/run_predefined_ai_smoke.sh
run_case "race screen integration" tests/integration/run_race_screen_integration.sh
run_case "network protocol and fake transport" tests/network/run_network_tests.sh
run_case "mobile private-room lifecycle single flight" tests/network/run_mobile_lifecycle_single_flight.sh
run_case "private-room product flow" tests/integration/run_private_room_ui_integration.sh
run_case "UI routes and clean shutdown" tests/ui/run_ui_route_smoke.sh
run_case "accessibility layout matrix" tests/ui/run_accessibility_layout_test.sh

if [[ ${WITH_SOAK} -eq 1 ]]; then
  run_case "frozen AI representative and corpus soak" tests/race/run_ai_soak.sh
fi

if [[ ${WITH_BACKEND} -eq 1 ]]; then
	run_case "backend compose configuration" backend/scripts/validate_compose.sh
  run_case "real Nakama end to end" backend/scripts/run_local_e2e.sh
fi

if [[ ${WITH_BACKEND_OPS} -eq 1 ]]; then
  run_case "real Nakama twelve-client load" backend/scripts/run_local_12_client_load.sh
  run_case "PostgreSQL backup and isolated restore" backend/scripts/run_backup_restore_drill.sh
fi

ALL_CHECKS_COMPLETE=1
