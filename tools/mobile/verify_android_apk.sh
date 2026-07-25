#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [path/to/RaceGlyph.apk]" >&2
  exit 64
fi

apk_path="${1:-builds/android/RaceGlyph-candidate.apk}"
expected_package="com.raceglyph.game"
expected_version_code="2"
expected_version_name="0.2.0"
expected_min_sdk="24"
expected_target_sdk="36"
expected_native_code="'arm64-v8a'"
expected_label="RaceGlyph"
expected_adaptive_icon="res/mipmap-anydpi-v26/icon.xml"

if [[ ! -f "${apk_path}" ]]; then
  echo "Android APK not found: ${apk_path}" >&2
  exit 66
fi

for required_command in awk grep sed sort unzip; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "Required command is unavailable: ${required_command}" >&2
    exit 69
  fi
done

# Prefer an explicitly configured SDK. The remaining locations cover the
# standard macOS Android Studio install and this workstation's SDK mount.
sdk_roots=()
for configured_root in \
  "${RACEGLYPH_ANDROID_SDK_ROOT:-}" \
  "${ANDROID_SDK_ROOT:-}" \
  "${ANDROID_HOME:-}" \
  "${HOME:-}/Library/Android/sdk" \
  "/Volumes/CodebaseSSD/Development/android"; do
  if [[ -n "${configured_root}" && -d "${configured_root}" ]]; then
    sdk_roots[${#sdk_roots[@]}]="${configured_root}"
  fi
done

aapt_path=""
apksigner_path=""
build_tools_dir=""

for sdk_root in "${sdk_roots[@]}"; do
  best_key=""
  best_dir=""
  for candidate_dir in "${sdk_root}"/build-tools/*; do
    if [[ ! -x "${candidate_dir}/aapt2" || ! -x "${candidate_dir}/apksigner" ]]; then
      continue
    fi

    candidate_version="${candidate_dir##*/}"
    candidate_key="$(printf '%s\n' "${candidate_version}" | awk -F. '{printf "%06d%06d%06d%06d", $1, $2, $3, $4}')"
    if [[ -z "${best_key}" || "${candidate_key}" > "${best_key}" ]]; then
      best_key="${candidate_key}"
      best_dir="${candidate_dir}"
    fi
  done

  if [[ -n "${best_dir}" ]]; then
    build_tools_dir="${best_dir}"
    # API 36 manifests emitted by current Godot templates use resource forms
    # that legacy aapt mis-parses. aapt2 is the authoritative package reader
    # for the same build-tools generation and still produces stable badging.
    aapt_path="${best_dir}/aapt2"
    apksigner_path="${best_dir}/apksigner"
    break
  fi
done

if [[ -z "${aapt_path}" || -z "${apksigner_path}" ]]; then
  if command -v aapt2 >/dev/null 2>&1 && command -v apksigner >/dev/null 2>&1; then
    aapt_path="$(command -v aapt2)"
    apksigner_path="$(command -v apksigner)"
    build_tools_dir="PATH"
  else
    echo "Could not locate a paired aapt2/apksigner installation." >&2
    echo "Set RACEGLYPH_ANDROID_SDK_ROOT, ANDROID_SDK_ROOT, or ANDROID_HOME." >&2
    exit 69
  fi
fi

failures=0

fail_check() {
  echo "FAIL $1" >&2
  failures=$((failures + 1))
}

check_equal() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if [[ "${actual}" != "${expected}" ]]; then
    fail_check "${label}: expected '${expected}', got '${actual:-<missing>}'"
  fi
}

if ! unzip -tqq "${apk_path}" >/dev/null 2>&1; then
  fail_check "APK ZIP integrity check"
fi

if ! badging="$(${aapt_path} dump badging "${apk_path}" 2>&1)"; then
  echo "${badging}" >&2
  fail_check "aapt could not read APK metadata"
  badging=""
fi

package_line="$(printf '%s\n' "${badging}" | sed -n '/^package:/{p;q;}')"
package_name="$(printf '%s\n' "${package_line}" | sed -n "s/.* name='\([^']*\)'.*/\1/p")"
version_code="$(printf '%s\n' "${package_line}" | sed -n "s/.* versionCode='\([^']*\)'.*/\1/p")"
version_name="$(printf '%s\n' "${package_line}" | sed -n "s/.* versionName='\([^']*\)'.*/\1/p")"
min_sdk="$(printf '%s\n' "${badging}" | sed -n \
  -e "s/^sdkVersion:'\([^']*\)'.*/\1/p" \
  -e "s/^minSdkVersion:'\([^']*\)'.*/\1/p")"
target_sdk="$(printf '%s\n' "${badging}" | sed -n "s/^targetSdkVersion:'\([^']*\)'.*/\1/p")"
native_code="$(printf '%s\n' "${badging}" | sed -n 's/^native-code: //p')"
application_label="$(printf '%s\n' "${badging}" | sed -n "s/^application-label:'\([^']*\)'.*/\1/p")"
application_icon="$(printf '%s\n' "${badging}" | sed -n "s/^application: .* icon='\([^']*\)'.*/\1/p")"
permissions="$(printf '%s\n' "${badging}" \
  | sed -n "s/^uses-permission: name='\([^']*\)'.*/\1/p" \
  | LC_ALL=C sort -u)"
expected_permissions="$(printf '%s\n' \
  android.permission.INTERNET \
  android.permission.VIBRATE \
  | LC_ALL=C sort)"

check_equal "package name" "${expected_package}" "${package_name}"
check_equal "version code" "${expected_version_code}" "${version_code}"
check_equal "version name" "${expected_version_name}" "${version_name}"
check_equal "minimum SDK" "${expected_min_sdk}" "${min_sdk}"
check_equal "target SDK" "${expected_target_sdk}" "${target_sdk}"
check_equal "native architectures" "${expected_native_code}" "${native_code}"
check_equal "application label" "${expected_label}" "${application_label}"
check_equal "adaptive launcher icon" "${expected_adaptive_icon}" "${application_icon}"
check_equal "requested permissions" "${expected_permissions}" "${permissions}"
if ! printf '%s\n' "${badging}" | grep -Fxq 'application-isGame'; then
  fail_check "Android application is not marked as a game"
fi

signature_output=""
if ! signature_output="$(${apksigner_path} verify --verbose --print-certs "${apk_path}" 2>&1)"; then
  echo "${signature_output}" >&2
  fail_check "APK signature verification"
else
  if ! printf '%s\n' "${signature_output}" | grep -Eq '^Number of signers: [1-9][0-9]*$'; then
    fail_check "APK has no reported signer"
  fi
  if ! printf '%s\n' "${signature_output}" \
      | grep -Eq '^Verified using v(2|3|3\.1|4) scheme .*: true$'; then
    fail_check "APK is not verified by a modern APK signature scheme"
  fi
fi

if [[ ${failures} -ne 0 ]]; then
  echo "Android APK verification failed (${failures} check(s)): ${apk_path}" >&2
  exit 1
fi

signer_count="$(printf '%s\n' "${signature_output}" | sed -n 's/^Number of signers: //p')"
build_kind="release-like"
if printf '%s\n' "${badging}" | grep -Fxq 'application-debuggable'; then
  build_kind="debuggable"
fi
echo "PASS Android APK: ${apk_path}"
echo "  package=${package_name} versionCode=${version_code} versionName=${version_name}"
echo "  label=${application_label} game=true icon=${application_icon} build=${build_kind}"
echo "  minSdk=${min_sdk} targetSdk=${target_sdk} native=${native_code}"
echo "  permissions=INTERNET,VIBRATE signers=${signer_count}"
echo "  build-tools=${build_tools_dir}"
