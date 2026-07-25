#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [path/to/exported-xcode-project]" >&2
  exit 64
fi

export_root="${1:-builds/ios/xcode}"
export_root="${export_root%/}"
plist_buddy="/usr/libexec/PlistBuddy"

if [[ ! -d "${export_root}" ]]; then
  echo "Exported iOS Xcode project not found: ${export_root}" >&2
  exit 66
fi

for required_command in awk find grep plutil sed sips sort tr; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "Required command is unavailable: ${required_command}" >&2
    exit 69
  fi
done
if [[ ! -x "${plist_buddy}" ]]; then
  echo "PlistBuddy is unavailable on this macOS host." >&2
  exit 69
fi

failures=0
expected_bundle_id="com.raceglyph.game"
expected_marketing_version="0.2.0"
expected_build_version="2"
expected_deployment_target="15.0"

fail_check() {
  echo "FAIL $1" >&2
  failures=$((failures + 1))
}

xcode_projects=()
for candidate_project in "${export_root}"/*.xcodeproj; do
  if [[ -d "${candidate_project}" ]]; then
    xcode_projects[${#xcode_projects[@]}]="${candidate_project}"
  fi
done
if [[ ${#xcode_projects[@]} -ne 1 ]]; then
  fail_check "expected exactly one top-level .xcodeproj, found ${#xcode_projects[@]}"
fi

if [[ ${#xcode_projects[@]} -eq 1 ]]; then
  project_file="${xcode_projects[0]}/project.pbxproj"
  if [[ ! -f "${project_file}" ]]; then
    fail_check "Xcode project file is missing: ${project_file}"
  else
    check_project_setting() {
      local key="$1"
      local expected="$2"
      local values

      values="$(sed -n "s/^[[:space:]]*${key} = \([^;]*\);[[:space:]]*$/\1/p" "${project_file}" \
        | tr -d '"' | LC_ALL=C sort -u)"
      if [[ "${values}" != "${expected}" ]]; then
        fail_check "${key}: expected '${expected}', got '${values:-<missing>}'"
      fi
    }

    check_project_setting PRODUCT_BUNDLE_IDENTIFIER "${expected_bundle_id}"
    check_project_setting MARKETING_VERSION "${expected_marketing_version}"
    check_project_setting CURRENT_PROJECT_VERSION "${expected_build_version}"
    check_project_setting IPHONEOS_DEPLOYMENT_TARGET "${expected_deployment_target}"
  fi

  if grep -R -Fq 'RACEGLYPH0' "${export_root}"; then
    fail_check "temporary export Team ID remains in the generated Xcode project"
  fi
fi

info_plists=()
while IFS= read -r -d '' candidate_plist; do
  info_plists[${#info_plists[@]}]="${candidate_plist}"
done < <(find "${export_root}" \
  -path "${export_root}/build" -prune -o \
  -type f -name '*-Info.plist' -print0)

if [[ ${#info_plists[@]} -ne 1 ]]; then
  fail_check "expected exactly one source app Info.plist, found ${#info_plists[@]}"
fi

if [[ ${#info_plists[@]} -ge 1 ]]; then
  info_plist="${info_plists[0]}"

  if ! plutil -lint "${info_plist}" >/dev/null; then
    fail_check "invalid app Info.plist: ${info_plist}"
  fi

  package_type="$(plutil -extract CFBundlePackageType raw -o - "${info_plist}" 2>/dev/null || true)"
  if [[ "${package_type}" != "APPL" ]]; then
    fail_check "CFBundlePackageType must be APPL, got '${package_type:-<missing>}'"
  fi

  for orientation_key in \
    UISupportedInterfaceOrientations \
    'UISupportedInterfaceOrientations~ipad'; do
    orientation_output="$(${plist_buddy} -c "Print :${orientation_key}" "${info_plist}" 2>/dev/null || true)"
    orientations="$(printf '%s\n' "${orientation_output}" \
      | sed -n 's/^[[:space:]]*\(UIInterfaceOrientation[^[:space:]]*\)[[:space:]]*$/\1/p' \
      | LC_ALL=C sort -u)"
    expected_orientations="$(printf '%s\n' \
      UIInterfaceOrientationLandscapeLeft \
      UIInterfaceOrientationLandscapeRight \
      | LC_ALL=C sort)"
    if [[ "${orientations}" != "${expected_orientations}" ]]; then
      fail_check "${orientation_key} must contain only landscape left and right"
    fi
  done

  plist_xml="$(plutil -convert xml1 -o - "${info_plist}" 2>/dev/null || true)"
  usage_keys="$(printf '%s\n' "${plist_xml}" \
    | sed -n 's/^[[:space:]]*<key>\([^<]*UsageDescription\)<\/key>[[:space:]]*$/\1/p')"
  while IFS= read -r usage_key; do
    if [[ -z "${usage_key}" ]]; then
      continue
    fi
    usage_value="$(plutil -extract "${usage_key}" raw -o - "${info_plist}" 2>/dev/null || true)"
    compact_value="$(printf '%s' "${usage_value}" | tr -d '[:space:]')"
    if [[ -z "${compact_value}" ]]; then
      fail_check "empty sensitive purpose string: ${usage_key}"
    fi
  done <<< "${usage_keys}"

  for unused_usage_key in \
    NSCameraUsageDescription \
    NSMicrophoneUsageDescription \
    NSPhotoLibraryUsageDescription; do
    if ${plist_buddy} -c "Print :${unused_usage_key}" "${info_plist}" >/dev/null 2>&1; then
      fail_check "unused sensitive purpose key is present: ${unused_usage_key}"
    fi
  done
fi

privacy_manifests=()
while IFS= read -r -d '' privacy_manifest; do
  privacy_manifests[${#privacy_manifests[@]}]="${privacy_manifest}"
done < <(find "${export_root}" \
  -path "${export_root}/build" -prune -o \
  -type f -name 'PrivacyInfo.xcprivacy' -print0)

if [[ ${#privacy_manifests[@]} -lt 1 ]]; then
  fail_check "PrivacyInfo.xcprivacy is missing"
fi

for privacy_manifest in "${privacy_manifests[@]}"; do
  if ! plutil -lint "${privacy_manifest}" >/dev/null; then
    fail_check "invalid privacy manifest: ${privacy_manifest}"
    continue
  fi

  tracking_value="$(plutil -extract NSPrivacyTracking raw -o - "${privacy_manifest}" 2>/dev/null || true)"
  if [[ "${tracking_value}" != "false" ]]; then
    fail_check "NSPrivacyTracking must be false in ${privacy_manifest}"
  fi

  manifest_name="${privacy_manifest##*/}"
  if [[ ${#xcode_projects[@]} -eq 1 ]] \
      && ! grep -Fq "${manifest_name} in Resources" "${xcode_projects[0]}/project.pbxproj"; then
    fail_check "${manifest_name} is not included in the Xcode Resources build phase"
  fi
done

app_icon_sets=()
while IFS= read -r -d '' app_icon_set; do
  app_icon_sets[${#app_icon_sets[@]}]="${app_icon_set}"
done < <(find "${export_root}" \
  -path "${export_root}/build" -prune -o \
  -type d -name '*.appiconset' -print0)

if [[ ${#app_icon_sets[@]} -lt 1 ]]; then
  fail_check "no .appiconset was found"
fi

icon_count=0
icon_1024_count=0
for app_icon_set in "${app_icon_sets[@]}"; do
  while IFS= read -r -d '' icon_path; do
    icon_count=$((icon_count + 1))
    if ! icon_metadata="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "${icon_path}" 2>&1)"; then
      fail_check "sips could not inspect ${icon_path}"
      continue
    fi

    width="$(printf '%s\n' "${icon_metadata}" | awk '/pixelWidth:/ {print $2; exit}')"
    height="$(printf '%s\n' "${icon_metadata}" | awk '/pixelHeight:/ {print $2; exit}')"
    has_alpha="$(printf '%s\n' "${icon_metadata}" | awk '/hasAlpha:/ {print $2; exit}')"

    if [[ -z "${width}" || -z "${height}" || "${width}" != "${height}" ]]; then
      fail_check "AppIcon must be square: ${icon_path} (${width:-?}x${height:-?})"
    fi
    if [[ "${has_alpha}" != "no" ]]; then
      fail_check "AppIcon must be opaque: ${icon_path} (hasAlpha=${has_alpha:-unknown})"
    fi
    if [[ "${width}" == "1024" && "${height}" == "1024" ]]; then
      icon_1024_count=$((icon_1024_count + 1))
    fi
  done < <(find "${app_icon_set}" -type f -iname '*.png' -print0)
done

if [[ ${icon_count} -lt 1 ]]; then
  fail_check "no PNG files were found in the AppIcon set"
fi
if [[ ${icon_1024_count} -lt 1 ]]; then
  fail_check "the AppIcon set has no 1024x1024 PNG"
fi

if [[ ${failures} -ne 0 ]]; then
  echo "iOS Xcode export verification failed (${failures} check(s)): ${export_root}" >&2
  exit 1
fi

echo "PASS iOS Xcode export: ${export_root}"
echo "  plist=${info_plists[0]}"
echo "  bundle=${expected_bundle_id} version=${expected_marketing_version} (${expected_build_version}) ios>=${expected_deployment_target}"
echo "  orientations=landscape-left,landscape-right (iPhone+iPad)"
echo "  privacy-manifests=${#privacy_manifests[@]} tracking=false"
echo "  app-icons=${icon_count} opaque=yes 1024x1024=${icon_1024_count}"
