# Device Matrix

Status: **current mobile-quality artifact and availability snapshot**, 2026-07-24. All current release components are green in combined development-host evidence, but no physical-device row has passed and there is no new one-shot `--release` PASS log. Emulator/export observations below are development diagnostics and do not replace the required physical matrix. Exact artifact and component evidence is indexed in [`TEST_REPORT.md`](TEST_REPORT.md).

## Status vocabulary

- `NOT RUN`: hardware may exist, but this build has no evidence.
- `BLOCKED—HARDWARE`: required class is unavailable to the project.
- `BLOCKED—SIGNING`: build is ready to test but credentials/profile are unavailable.
- `BLOCKED—HOST TOOLCHAIN`: the required local SDK/platform component is unavailable even though project generation can proceed.
- `DEVELOPMENT OBSERVATION`: an emulator/export diagnostic exists, but is not a release-device PASS.
- `FAIL`: evidence exists and a requirement failed.
- `PASS`: the exact build and scripted checks passed with linked evidence.

Simulator/emulator passes are recorded separately and never substitute for physical performance, thermal, touch, haptics, lifecycle, or release proof.

## Required physical matrix

| Class | Exact device/OS | Required focus | Current status |
|---|---|---|---|
| Older supported iPhone | TBD after support-floor decision | 30 FPS fallback, memory, touch, background/resume | BLOCKED—HARDWARE |
| Modern iPhone | TBD | 60 FPS, haptics, safe areas, multiplayer | BLOCKED—HARDWARE |
| iPad/tablet | TBD | responsive layout, aspect/safe area, controller | BLOCKED—HARDWARE |
| Mainstream Android | TBD | 60/30 pacing, touch, vibration, resume | BLOCKED—HARDWARE |
| Android flagship | TBD | 60 FPS worst case, high refresh behavior | BLOCKED—HARDWARE |
| Lower-memory Android floor | TBD after profiling | memory pressure, 30 FPS fallback, thermal | BLOCKED—HARDWARE |

“TBD” is intentional: a device class does not pass until an exact model, chipset/memory, OS/build, and app artifact are recorded.

## Local availability observed

- `adb devices -l` listed no attached Android hardware.
- Android SDK API 36 and an Android 16/API 36 AVD named `RaceGlyph_API36` are available. The current [`../builds/android/RaceGlyph-mobile-optimized.apk`](../builds/android/RaceGlyph-mobile-optimized.apk) is 44,435,606 bytes with SHA-256 `536c14941a1a8d08fe73a514986f54da271b72b3dc56018ccc0cd1a50735e05b`; static/signature audit passed `com.raceglyph.game`, version `0.2.0` (`2`), min API 24, target API 36, ARM64, exactly `INTERNET` + `VIBRATE`, game/adaptive-icon metadata, debuggable, and one signer.
- The shipping Vulkan APK installed and initialized Godot in the API 36 AVD, but neither the available SwiftShader nor host-GPU path could present its Vulkan surface (`VkResult 5`); the process terminated inside the emulator Vulkan stack. That row is `BLOCKED—EMULATOR GRAPHICS`, not a runtime PASS and not evidence of a phone defect.
- A separately exported temporary **non-shipping GL-compatibility build** rendered and navigated [menu](../evidence/screenshots/android_mobile_optimized_20260724/menu_gl_smoke.png), [offline setup](../evidence/screenshots/android_mobile_optimized_20260724/offline_setup_gl_smoke.png), [12-car race](../evidence/screenshots/android_mobile_optimized_20260724/race_12car_gl_smoke.png), and [active driving](../evidence/screenshots/android_mobile_optimized_20260724/race_driving_gl_smoke.png) to 184 km/h in gear 5. This proves the exported content and touch navigation can execute in that alternate renderer; it does not qualify the shipping Vulkan artifact or establish FPS/thermal performance.
- The current Android release preset targets API 36, has minimum API 24, and emits ARM64 only. A current owner-signed release AAB, protected release keystore, Play internal/pre-launch result, and device-qualified support floor remain unavailable.
- Xcode 26.0.1 is selected and lists the iOS 26.0 SDK, but `xcodebuild -showdestinations` reports no eligible destination because the iOS 26.0 platform is not installed in Xcode Components.
- `simctl` reported installed iOS 18.5 and iOS 26.0 runtimes as unavailable; no available simulator was listed.
- Godot generated the fresh unsigned current-source Xcode project at [`../builds/ios/mobile-optimized`](../builds/ios/mobile-optimized). The temporary Team ID required only for generation was scrubbed from source and generated output. Static audit passed `com.raceglyph.game`, version `0.2.0` (`2`), iOS 15.0 minimum, both iPhone/iPad landscape orientations, privacy tracking false, absent sensitive usage keys, and 16/16 opaque icons including 1024×1024. Evidence: [`../evidence/logs/ios-xcode-export-mobile-optimized-20260724T142020Z.log`](../evidence/logs/ios-xcode-export-mobile-optimized-20260724T142020Z.log), log SHA-256 `aac0642eb00de00063fe6127e9f74dac3f75ad1a5c2d1cbf4eb6de2322d5be75`; packed project SHA-256 `ebf5d3f7f7f8ede05d9ec63f380617bb36256226c43c1b47c44970855b82747c`.
- Apple signing identity, provisioning profile, developer team, archive/TestFlight access, eligible build/simulator destination, and physical iOS devices were not verified.

These observations are not physical performance, thermal, haptic, lifecycle, controller, signing, or store-readiness tests.

## Current non-device release-component evidence

- The one-shot [`../evidence/logs/full-check-20260724T142719Z.log`](../evidence/logs/full-check-20260724T142719Z.log), SHA-256 `3727c0960a494ef71745cb8a72dbefe496fcb54e85ae63e6d67cd4d409194682`, passed every pre-soak check and all AI correctness but stopped solely when the current longer-track work took 2,075,104 ms against the obsolete 900,000 ms absolute gate. It is not a one-shot PASS.
- The unchanged-coverage schema-2 [`../evidence/runtime/ai_soak_report.json`](../evidence/runtime/ai_soak_report.json), SHA-256 `aeb497dd8dc6b3c5e439eb03b14b6437e6f75f527923e90c8b45afa63abc2247`, passed in 2,084,371 ms under its rebaselined 2,700,000 ms ceiling and at 1,407.6 authority vehicle-steps/s above its 1,100 minimum. It covered 122,246 primary ticks, 2,933,904 twin vehicle-steps, 4/4 representative runs, 20/20 corpus tracks, and 288/288 deterministic finishes with zero DNF/invalid/non-finite/stuck/recovery outcomes.
- Current disposable backend reruns passed real Nakama E2E (102 assertions), the twelve-client load (1,011 assertions; [`log`](../evidence/logs/nakama-12-client-load-20260724T154614Z.log), SHA-256 `e91055a45f4f2aa442db43ce659cfeff7978d099831f53a491d2640023bc386a`), and isolated PostgreSQL backup/restore (12 checks; [`log`](../evidence/logs/postgres-backup-restore-20260724T154648Z.log), SHA-256 `782bfd3907de2983f75766e7f856aba977f573f13f11862f867c5616695a7bde`).

These checks make every release component green in combined local evidence. They do not produce physical-device, network-radio, public-service, or one-shot immutable-candidate proof.

Private-room mobile lifecycle, system Back, leave, reconnect, ready-phase, kick, and rejoin-ban behavior is covered by deterministic and disposable local tests, but two-phone internet validation remains blocked. The supplied Compose service binds loopback and no public TLS/WSS endpoint or managed mobile endpoint/key is configured. Even after hosting, the 30-bit friend code and identity/node-local limiter are not public-scale brute-force protection, and the simulation host remains trusted for snapshots/results.

## Per-device manual script

1. Install the exact recorded debug/internal artifact; verify original icon/splash, landscape lock, first launch, safe area, and no unexpected permission prompt.
2. Draw with touch, undo/redo/clear, test near-closure and invalid shapes, inspect auto-fix, save/reload/edit/delete.
3. Tour predefined, technical, dense forest, and bridge tracks; inspect joins, layers, occlusion, text, and controls.
4. Race a 12-car grid through first corner; complete laps, pause, background/resume, interrupt audio, recover/reset, finish/results/restart.
5. Exercise left-handed layout, text/control scaling, high contrast, color-independent states, assists, reduced shake, haptics, and category volumes.
6. Create/join a private room on two physical networks when available; ready/hash/start, race, loss/reconnect, background, host departure, backend outage.
7. Run the 20-lap AI soak and 30-minute thermal scenario while capturing frame/memory/thermal evidence.
8. Export/delete local data, relaunch after a forced termination, verify corrupt-save recovery, and inspect logs for secrets/critical errors.

## Evidence required for PASS

Artifact checksum, commit/build ID, export preset, device model/identifier, RAM/chipset where available, OS build, test date/operator, start/end battery and thermal state, results per step, profiler/log/screenshot/video paths, defects, and retest disposition.

## External actions eventually required

The owner must provide or authorize representative physical devices, an Android release keystore/Play account, and Apple signing/TestFlight credentials. The host also needs an installed usable iOS platform/runtime before Xcode build or simulator smoke can proceed. Store publishing, paid developer enrollment, device purchase/rental, and public distribution require explicit approval; unblocked implementation and unsigned/export checks should continue first.
