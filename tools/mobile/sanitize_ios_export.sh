#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [path/to/App-Info.plist]" >&2
  exit 64
fi

plist_path="${1:-builds/ios/xcode/RaceGlyph/RaceGlyph-Info.plist}"
plist_buddy="/usr/libexec/PlistBuddy"

if [[ ! -f "${plist_path}" ]]; then
  echo "iOS export plist not found: ${plist_path}" >&2
  exit 66
fi
if [[ ! -x "${plist_buddy}" ]]; then
  echo "PlistBuddy is unavailable on this macOS host." >&2
  exit 69
fi

# Godot 4.7 emits these three template keys even when the corresponding
# project capabilities and usage descriptions are disabled. Empty purpose
# strings are neither useful nor an honest privacy declaration, so remove only
# empty values. A future non-empty value is preserved and reported.
privacy_keys=(
  NSCameraUsageDescription
  NSMicrophoneUsageDescription
  NSPhotoLibraryUsageDescription
)

for privacy_key in "${privacy_keys[@]}"; do
  if value="$("${plist_buddy}" -c "Print :${privacy_key}" "${plist_path}" 2>/dev/null)"; then
    if [[ -n "${value}" ]]; then
      echo "Keeping non-empty ${privacy_key}."
      continue
    fi
    "${plist_buddy}" -c "Delete :${privacy_key}" "${plist_path}"
    echo "Removed empty ${privacy_key}."
  fi
done

plutil -lint "${plist_path}" >/dev/null
for privacy_key in "${privacy_keys[@]}"; do
  if value="$("${plist_buddy}" -c "Print :${privacy_key}" "${plist_path}" 2>/dev/null)" \
      && [[ -z "${value}" ]]; then
    echo "Empty ${privacy_key} remains after sanitization." >&2
    exit 1
  fi
done

echo "PASS iOS export privacy plist"
