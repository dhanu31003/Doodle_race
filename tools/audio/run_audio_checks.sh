#!/bin/sh
set -eu

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(unset CDPATH; cd -- "$SCRIPT_DIR/../.." && pwd)

cd "$PROJECT_ROOT"
python3 tools/audio/generate_original_audio.py --check
godot --headless --path . --script res://tests/unit/run_audio_tests.gd
godot --headless --path . --script res://tests/unit/run_audio_playback_smoke.gd
