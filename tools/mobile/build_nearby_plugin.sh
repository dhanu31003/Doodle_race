#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
template_gradle="${repo_root}/android/build/gradlew"
plugin_root="${repo_root}/native/nearby-plugin"
addon_root="${repo_root}/addons/RaceGlyphNearby/bin"

if [[ ! -x "${template_gradle}" ]]; then
  godot --headless --path "${repo_root}" --install-android-build-template --quit
fi

# play-services-nearby 19.4.0 declares Java-library desugaring metadata. Godot's
# generated custom template does not enable it yet, so patch that generated,
# gitignored template idempotently before either plugin or APK assembly.
template_build="${repo_root}/android/build/build.gradle"
template_properties="${repo_root}/android/build/gradle.properties"
if ! grep -q 'coreLibraryDesugaringEnabled true' "${template_build}"; then
  perl -0pi -e 's/(compileOptions \{\n)/$1        coreLibraryDesugaringEnabled true\n/' "${template_build}"
fi
if ! grep -q 'desugar_jdk_libs:2.1.5' "${template_build}"; then
  perl -0pi -e 's/(dependencies \{\n)/$1    coreLibraryDesugaring "com.android.tools:desugar_jdk_libs:2.1.5"\n\n/' "${template_build}"
fi
grep -q 'coreLibraryDesugaringEnabled true' "${template_build}"
grep -q 'desugar_jdk_libs:2.1.5' "${template_build}"
if ! grep -q '^android.suppressUnsupportedCompileSdk=36$' "${template_properties}"; then
  printf '\nandroid.suppressUnsupportedCompileSdk=36\n' >>"${template_properties}"
fi

"${template_gradle}" -p "${plugin_root}" :plugin:assemble
mkdir -p "${addon_root}/debug" "${addon_root}/release"
install -m 0644 \
  "${plugin_root}/plugin/build/outputs/aar/RaceGlyphNearby-debug.aar" \
  "${addon_root}/debug/RaceGlyphNearby-debug.aar"
install -m 0644 \
  "${plugin_root}/plugin/build/outputs/aar/RaceGlyphNearby-release.aar" \
  "${addon_root}/release/RaceGlyphNearby-release.aar"

printf 'Nearby plugin AARs installed in %s\n' "${addon_root}"
