# RaceGlyph

RaceGlyph is the provisional working name for an original landscape draw-to-race game for Android and iOS. A player sketches a closed loop, the game validates and compiles it into a deterministic circuit, and a configurable 2–12-driver field races it from a switchable cockpit or elevated chase view. Circuit authoring, tours, and the minimap may use plan view; active driving does not.

> **Android release candidate (2026-08-30):** RaceGlyph `0.6.0` adds an analog mobile steering wheel, release-only scrollable option sheets, a bounded mobile shadow/contact-shadow path, and three-phase opponent cosmetic updates on top of Google Nearby multiplayer. Focused gameplay/UI/network/3D tests and the signed APK/AAB audits pass. Physical phone/tablet pairing, thermal profiling, identity/legal review, and Play review remain open. See [`docs/PROJECT_STATUS.md`](docs/PROJECT_STATUS.md), [`docs/TEST_REPORT.md`](docs/TEST_REPORT.md), and [`docs/RELEASE_CHECKLIST.md`](docs/RELEASE_CHECKLIST.md).

The name **RaceGlyph has not received trademark, store-name, domain, or other legal clearance**. It must not be used publicly until the owner approves a cleared final identity.

## What is implemented

- Track Studio: draw, closure guidance, undo/redo/clear, deterministic validation, very-local extreme-corner rounding, automatic safe grid/bridge placement, direct generation/tour, a separate World & Road section, save/reload/edit/export/delete, and same-room multiplayer authoring.
- Deterministic circuits: canonical versioned JSON, content hashes, road/curbs/runoff/barriers, pits, grid, checkpoints, lanes, minimap, bridges, recovery data, seeded forest decoration, and five selectable road surfaces with distinct road texture, vehicle coating, moving effects, and authoritative handling.
- Offline racing: one player plus 1–11 AI opponents, analog wheel/tilt steering, accelerator and brake-reverse pedals, assists, collisions, recovery, bounded gravity-driven crest airtime, smoothly grade-following cockpit/chase views, HUD/pause, a live post-finish full-field classification with exact times, effects, and category audio.
- Content and presentation: six predefined circuits, eight original fictional car colorways, a complete forest theme, responsive safe-area UI, accessibility controls, credits, and licenses.
- Nearby multiplayer: up to 12 Android devices through Google Nearby Connections `P2P_STAR`, anonymous local identity, create/code-join, creator-phone 60 Hz race authority, first-frame guest prediction, host reconciliation, explicit lock/readiness, custom-track hash verification, results/share/rematch, and no Internet or PC requirement. The room ends if the creating phone leaves. Private-room AI fill is deferred.
- Local data controls: atomic versioned persistence, corruption fallback/migrations, portable local export, and Delete All Local Data with runtime token/session clearing.

## Current verification record

The authoritative command is:

```sh
tools/qa/run_all_checks.sh --release
```

The normal run at `20260818T220217Z` exited `0` and ended with `PASS all requested checks`. Its complete log is [`evidence/logs/full-check-20260818T220217Z.log`](evidence/logs/full-check-20260818T220217Z.log), SHA-256 `a056cf180e7a43ed02849e5b99779547abbf6654db685136a0a66cd22f1dcd2c`.

That gate covers asset/source/privacy contracts, editor parse, track/render/physics/persistence/audio/gameplay suites, 423 network assertions (including a deterministic two-device Nearby bridge and peer-host race authority), 13 UI routes, 26 accessibility fixtures, and a deterministic six-circuit 12-car finish smoke. Exact limitations and historical cloud evidence are in [`docs/TEST_REPORT.md`](docs/TEST_REPORT.md).

## Mobile artifacts

### Android 0.6.0 signed candidate

- APK: [`builds/android/RaceGlyph-0.6.0-release.apk`](builds/android/RaceGlyph-0.6.0-release.apk)
- APK SHA-256: `6036715fe32994ca2776a41e934e19b4bbc8a0dda1183b2657c00cd31c5c2f00`
- AAB: [`builds/android/RaceGlyph-0.6.0-release.aab`](builds/android/RaceGlyph-0.6.0-release.aab)
- AAB SHA-256: `26f1ee4d753277d0596ea6517953311d36ef87508bffb34e1d6a89df225f4563`

The release-signed artifacts are `com.raceglyph.game` version `0.6.0` (`6`), minimum API 24, target API 36, and ARM64-only. Static audit confirms one Neutale upload signer, the native `RaceGlyphNearbyPlugin`, Google Nearby runtime, and Android-version-scoped Bluetooth, Wi-Fi, location, Nearby devices, and local-network permissions. They are upload-capable candidates, but Play acceptance and physical-device qualification are not yet claimed.

### iOS project candidate

- Xcode export: [`builds/ios/final`](builds/ios/final)
- Export audit: [`evidence/logs/ios-xcode-export-final-20260723T214053Z.log`](evidence/logs/ios-xcode-export-final-20260723T214053Z.log)
- Host build attempt: [`evidence/logs/ios-xcode-host-build-20260723T214053Z.log`](evidence/logs/ios-xcode-host-build-20260723T214053Z.log)
- Packed project SHA-256: `3a1117d85610bdade244c0b470c8d646089b526facf3c5417728cf23cd13365d`

The unsigned project audit verifies `com.raceglyph.game`, `0.1.0` (`1`), iOS 15.0 deployment target, both landscape orientations on iPhone/iPad, no sensitive usage-description keys, tracking disabled in the privacy manifest, and 16/16 opaque icons including 1024×1024. The no-sign host build reached storyboard compilation and stopped exactly because `iOS 26.0 Platform Not Installed`; Apple team, certificate/profile, archive validation, TestFlight, and physical iPhone/iPad tests remain external gates. The source preset contains no dummy team ID.

## Pinned baseline

- Godot `4.7.1.stable.official.a13da4feb`
- GDScript with deterministic 2D race authority mapped into a true world-space 3D race renderer
- Google Play services Nearby `19.4.0` through a Godot Android v2 plugin
- Retained, non-shipping Nakama/PostgreSQL cloud prototype for possible later work
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
- Public mobile multiplayer deployment: [`docs/BACKEND_PRODUCTION.md`](docs/BACKEND_PRODUCTION.md)
- Art and licensing: [`docs/ART_DIRECTION.md`](docs/ART_DIRECTION.md), [`docs/ASSET_LICENSES.md`](docs/ASSET_LICENSES.md)
- Performance and devices: [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md), [`docs/DEVICE_MATRIX.md`](docs/DEVICE_MATRIX.md)
- Privacy and release: [`docs/PRIVACY_DATA_MAP.md`](docs/PRIVACY_DATA_MAP.md), [`docs/RELEASE_CHECKLIST.md`](docs/RELEASE_CHECKLIST.md)

## Legal boundary

The behavioral reference supplied with the project is inspiration only. Do not copy its name, screens, logos, sponsors, teams, drivers, cars, liveries, textures, audio, source code, or marketing material. Do not use Formula 1 branding or protected real-world identities. Every shipped asset needs a cleared license-ledger entry before public release.
