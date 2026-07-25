#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_DIR}"

node --check backend/modules/index.js

shell_files=()
while IFS= read -r shell_file; do
  shell_files+=("${shell_file}")
done < <(rg --files backend tests tools | rg '\.sh$')
for shell_file in "${shell_files[@]}"; do
  bash -n "${shell_file}"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${shell_files[@]}"
fi

if rg -n 'logger\..*(roomCode|room_code|reconnectToken|reconnect_token|String\(error\))' \
    backend/modules backend/config; then
  echo "Release contract failed: a private room/session value can reach backend logs." >&2
  exit 1
fi

if rg -n 'PRE-ALPHA|COMING SOON' game project.godot export_presets.cfg; then
  echo "Release contract failed: player-facing prerelease placeholder remains." >&2
  exit 1
fi

if rg -n 'privacy/(camera|microphone|photo_?library|photolibrary)_usage_description=""' export_presets.cfg; then
  echo "Release contract failed: unused iOS privacy capability has an empty usage string." >&2
  exit 1
fi
if ! rg -q '^driver/enable_input=false$' project.godot \
    || ! rg -q '^modules/camera=false$' export_presets.cfg; then
  echo "Release contract failed: unused microphone or camera input remains enabled." >&2
  exit 1
fi

if rg -n 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|sk_live_[A-Za-z0-9]+' \
    . --glob '!game/network/nakama/vendor/**' --glob '!evidence/**' --glob '!builds/**'; then
  echo "Release contract failed: credential-shaped source content found." >&2
  exit 1
fi

echo "PASS source, privacy, redaction, placeholder, and shell contracts"
