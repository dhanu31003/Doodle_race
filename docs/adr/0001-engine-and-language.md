# ADR 0001: Engine and Language

- Status: Accepted
- Date: 2026-07-23
- Implementation status: Godot project, headless/integration runners, deterministic capture scenes, and Android/iOS export presets implemented; exact platform results tracked separately

## Context

The game requires custom 2D curve rendering, deterministic geometry, arcade physics, particles/shaders, touch/controller input, headless tests, and Android/iOS exports. Mobile export risk and a single editable toolchain matter more than sharing gameplay code with a separate server.

Godot 4.7.1 is the newest stable release at the decision date; 4.8 is a development release. The local host reports `4.7.1.stable.official.a13da4feb` with matching export templates.

## Decision

Use Godot **4.7.1 stable**, GDScript, Godot's dedicated 2D renderer and 2D physics, and landscape orientation.

Keep track math, canonical serialization/hashing, migrations, race rules, AI decisions, and protocol codecs as scene-independent GDScript operating on plain values. Use a custom headless GDScript runner plus integration and deterministic screenshot scenes.

Pin the engine/export-template version in project documentation and CI/build manifests. Upgrade only through a new ADR or explicit amendment with clean unit/integration/visual/Android/iOS export comparisons. If 4.7.1 has a release-blocking incompatibility, select the newest stable version that passes both target exports and record the evidence.

## Platform baseline observed

- Android: Java 17.0.12; SDK platforms through API 36; Build-Tools 35.0.1/36.0.0; NDK r28b (`28.1.13356709`); CMake `3.10.2.4988404`; ADB 36.0.0. The implemented presets select ARM64, API 24 minimum/API 36 target for the AAB path, landscape, adaptive/monochrome icons, `INTERNET` and `VIBRATE`, and disabled user backup. Development APK/emulator observations are recorded separately; owner-keystore signing, physical-device coverage, and Play validation remain release gates.
- iOS: Xcode 26.0.1 build 17A400, selected developer directory `/Applications/Xcode.app/Contents/Developer`, and an iOS 26.0 SDK listing. The implemented preset selects ARM64, landscape in both directions, iOS project-only export, disabled camera module, and no owner Team ID in source. Project generation is possible with a temporary placeholder Team ID, but Xcode build is blocked on this host by the missing iOS 26.0 platform component; signing, device, archive, and TestFlight results are not claimed.

## Alternatives considered

- **C# in Godot:** familiar static typing, but Godot documents mobile C# export support as experimental and it adds .NET/mobile export surface. Rejected for the initial release.
- **Unity:** capable mobile/2D tooling but adds a different licensing/editor stack and is unnecessary for the data-first 2D scope. Rejected.
- **Native dual-platform clients:** maximum platform control but duplicate implementation and much higher delivery/test cost. Rejected.
- **Custom engine/framework:** offers control but would recreate mature rendering, input, export, and editor systems. Rejected.

## Consequences

- One first-class language/toolchain supports editor, desktop tests, and mobile clients.
- GDScript discipline and explicit value contracts replace compiler-enforced domain boundaries.
- Native plugins are exceptions requiring license, ABI, privacy, and both-platform evidence.
- Exact determinism still needs golden cross-platform tests; engine pinning alone does not guarantee it.
- Store signing, physical devices, and final package/bundle identities remain external decisions.

## References

- Godot release archive: <https://godotengine.org/download/archive/>
- Android export: <https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_android.html>
- iOS export: <https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_ios.html>
- Xcode 26 release notes: <https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes>
