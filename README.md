# RaceGlyph

RaceGlyph is the provisional working name for an original landscape draw-to-race game for Android and iOS. A player sketches a closed loop, the game validates and compiles it into a deterministic circuit, and a configurable 2–12-driver field races it from a switchable cockpit or elevated chase view. Circuit authoring, tours, and the minimap may use plan view; active driving does not.

> **Candidate state (2026-07-24):** the game and local multiplayer/backend candidate are feature-complete against the implemented v1 scope, and the frozen automated release gate passes. This is **not a store-ready release**: the working tree is dirty/untracked, physical-device and 30-minute thermal qualification are not available, Android release signing is owner-blocked, iOS build/sign/archive is platform- and owner-blocked, and identity/legal/store/public-service approvals remain open. See [`docs/PROJECT_STATUS.md`](docs/PROJECT_STATUS.md), [`docs/TEST_REPORT.md`](docs/TEST_REPORT.md), and [`docs/RELEASE_CHECKLIST.md`](docs/RELEASE_CHECKLIST.md).

The name **RaceGlyph has not received trademark, store-name, domain, or other legal clearance**. It must not be used publicly until the owner approves a cleared final identity.

## What is implemented

- Track Studio: draw, closure guidance, undo/redo/clear, deterministic validation, very-local extreme-corner rounding, automatic safe grid/bridge placement, direct generation/tour, a separate World & Road section, save/reload/edit/export/delete, and same-room multiplayer authoring.
- Deterministic circuits: canonical versioned JSON, content hashes, road/curbs/runoff/barriers, pits, grid, checkpoints, lanes, minimap, bridges, recovery data, seeded forest decoration, and five selectable road surfaces with distinct road texture, vehicle coating, moving effects, and authoritative handling.
- Offline racing: one player plus 1–11 AI opponents, conventional steering/accelerator/brake-reverse controls, assists, collisions, recovery, bounded gravity-driven crest airtime, smoothly grade-following cockpit/chase views, HUD/pause, a live post-finish full-field classification with exact times, effects, and category audio.
- Content and presentation: six predefined circuits, eight original fictional car colorways, a complete forest theme, responsive safe-area UI, accessibility controls, credits, and licenses.
- Private multiplayer: up to 12 humans through pinned Nakama/PostgreSQL, anonymous sessions, create/code-join, host authority, explicit lock/readiness, custom-track hash verification, relay/prediction, reconnect, host departure, results/share/rematch, and offline fallback. Private-room AI fill is intentionally deferred from v1.
- Local data controls: atomic versioned persistence, corruption fallback/migrations, portable local export, and Delete All Local Data with runtime token/session clearing.

## Frozen verification record

The authoritative command is:

```sh
tools/qa/run_all_checks.sh --release
```

The frozen run at `20260723T214917Z` exited `0` after 817 seconds and ended with `PASS all requested checks`. Its complete log is [`evidence/logs/full-check-20260723T214917Z.log`](evidence/logs/full-check-20260723T214917Z.log), SHA-256 `7be77897455026022b9554a20022fc37c7fc1bfd3fefafb1c881113e709215fc`. A strict whole-log audit found zero `FAIL`, `WARNING`, `ERROR`, parse/compile faults, ObjectDB leaks, or resource leaks.

That gate covers asset/source/privacy contracts, editor parse, 2,158 focused game/network assertions, audio playback, 13 UI routes, 15 accessibility fixtures, a deterministic 12-car AI soak, real local Nakama E2E/load, and isolated PostgreSQL backup/restore. Exact suite counts, hashes, limitations, and the closed pre-freeze leak regression are in [`docs/TEST_REPORT.md`](docs/TEST_REPORT.md).

## Mobile artifacts

### Android development candidate

- APK: [`builds/android/RaceGlyph-final.apk`](builds/android/RaceGlyph-final.apk)
- SHA-256: `590b75e0369a6f7d9c42122d58d88cb213459e5a254a8d13d7f42fc943f63c42`
- Audit: [`evidence/logs/android-apk-final-20260723T213702Z.log`](evidence/logs/android-apk-final-20260723T213702Z.log)
- API 36 emulator runtime: [`evidence/logs/android-runtime-final-20260723T214441Z.log`](evidence/logs/android-runtime-final-20260723T214441Z.log)
- Warm-launch capture: [`evidence/screenshots/actual/raceglyph_android_final_warm2.png`](evidence/screenshots/actual/raceglyph_android_final_warm2.png)

The debug-signed APK is `com.raceglyph.game` version `0.1.0` (`1`), minimum API 24, target API 36, ARM64-only, and requests exactly `INTERNET` and `VIBRATE`. It installed, warm-launched, and rendered the menu on the API 36 emulator with no critical app-runtime pattern. An unsigned Gradle AAB payload (`jar is unsigned`) exists at [`builds/android/RaceGlyph-final-debug.aab`](builds/android/RaceGlyph-final-debug.aab), SHA-256 `bc2b5be4be7e89b77c1895b1c9f08619175e5021a931aaeddf5ca1f0a068940e`; it is not a store artifact.

### iOS project candidate

- Xcode export: [`builds/ios/final`](builds/ios/final)
- Export audit: [`evidence/logs/ios-xcode-export-final-20260723T214053Z.log`](evidence/logs/ios-xcode-export-final-20260723T214053Z.log)
- Host build attempt: [`evidence/logs/ios-xcode-host-build-20260723T214053Z.log`](evidence/logs/ios-xcode-host-build-20260723T214053Z.log)
- Packed project SHA-256: `3a1117d85610bdade244c0b470c8d646089b526facf3c5417728cf23cd13365d`

The unsigned project audit verifies `com.raceglyph.game`, `0.1.0` (`1`), iOS 15.0 deployment target, both landscape orientations on iPhone/iPad, no sensitive usage-description keys, tracking disabled in the privacy manifest, and 16/16 opaque icons including 1024×1024. The no-sign host build reached storyboard compilation and stopped exactly because `iOS 26.0 Platform Not Installed`; Apple team, certificate/profile, archive validation, TestFlight, and physical iPhone/iPad tests remain external gates. The source preset contains no dummy team ID.

## Pinned baseline

- Godot `4.7.1.stable.official.a13da4feb`
- GDScript with deterministic 2D race authority mapped into a true world-space 3D race renderer
- Nakama `3.40.0` image pinned by digest
- Official Nakama Godot SDK `3.4.0` pinned to commit `14b7f7078a9822c15b0424624e4c883c87730cee`
- PostgreSQL `17.9-alpine3.23` image pinned by digest
- Versioned canonical JSON `TrackDefinition` with SHA-256 source and compiled fingerprints

See [`docs/adr/0001-engine-and-language.md`](docs/adr/0001-engine-and-language.md) and [`docs/adr/0002-multiplayer-architecture.md`](docs/adr/0002-multiplayer-architecture.md) for the decisions and trade-offs.

## Local toolchain snapshot

Observed on 2026-07-23/24:

- Godot 4.7.1 and matching export templates
- Java 17.0.12
- Android SDK API 36, Build-Tools 36.0.0, NDK 28.1.13356709, and CMake 3.10.2.4988404 under `/Volumes/CodebaseSSD/Development/android`
- Xcode 26.0.1 (build 17A400); the iOS 26.0 SDK is visible but the host's iOS platform component is not usable by Interface Builder
- Docker 29.3.1

No Android or Apple hardware was available for the frozen candidate. The development package/bundle ID remains owner-unapproved. Release signing material must never enter Git.

## Working in the repository

Open the project with the pinned editor:

```sh
godot --editor --path .
```

Run the fast local suite:

```sh
tools/qa/run_all_checks.sh
```

Run the complete frozen gate, including AI soak and disposable real-backend operations:

```sh
tools/qa/run_all_checks.sh --release
```

The release mode starts and tears down disposable local Nakama/PostgreSQL resources. It does not deploy a public service.

## Documentation map

- Product scope: [`docs/PRODUCT_SPEC.md`](docs/PRODUCT_SPEC.md)
- System boundaries: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- Track contract: [`docs/TRACK_FORMAT.md`](docs/TRACK_FORMAT.md)
- AI contract: [`docs/AI.md`](docs/AI.md)
- Multiplayer wire contract: [`docs/NETWORK_PROTOCOL.md`](docs/NETWORK_PROTOCOL.md)
- Backend operations: [`docs/BACKEND_OPERATIONS.md`](docs/BACKEND_OPERATIONS.md)
- Art and licensing: [`docs/ART_DIRECTION.md`](docs/ART_DIRECTION.md), [`docs/ASSET_LICENSES.md`](docs/ASSET_LICENSES.md)
- Performance and devices: [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md), [`docs/DEVICE_MATRIX.md`](docs/DEVICE_MATRIX.md)
- Privacy and release: [`docs/PRIVACY_DATA_MAP.md`](docs/PRIVACY_DATA_MAP.md), [`docs/RELEASE_CHECKLIST.md`](docs/RELEASE_CHECKLIST.md)

## Legal boundary

The behavioral reference supplied with the project is inspiration only. Do not copy its name, screens, logos, sponsors, teams, drivers, cars, liveries, textures, audio, source code, or marketing material. Do not use Formula 1 branding or protected real-world identities. Every shipped asset needs a cleared license-ledger entry before public release.
