# Test Report

Status: **current mobile-quality local evidence index**, updated 2026-07-26.

## Verdict

The current mobile-quality game passes the complete normal automated gate, including five visually and physically distinct deterministic road surfaces, surface-specific car coating, bounded moving rain/spray/debris, grade-aligned cars, smoothed chase bridge pitch, live post-finish full-field classification, chase-only halo removal, local-only extreme-corner rounding, automatic grid placement, six unusual default circuits, calibrated crest airtime, two-tier scenery clearance, a six-circuit twelve-car finish smoke, private-room client coverage, and mobile Track Studio layouts. There is deliberately no claim of a new one-shot `tools/qa/run_all_checks.sh --release` PASS: the full frozen soak and backend operational components remain represented by older targeted evidence until protocol 3 is requalified there. The 2026-07-23 one-shot release result below remains historical pre-upgrade regression evidence only.

The current mobile-optimized Android APK passes static/signature audit, but its shipping Vulkan renderer could not present a surface in the available API 36 emulator's SwiftShader or host-GPU backend. A temporary non-shipping GL-compatibility smoke build did render and navigate through menu, setup, a twelve-car race, and active driving. The current unsigned iOS Xcode project passes static export audit, but no eligible iOS build/signing destination exists on this host.

The product remains **NO-GO for public/store release**. The evidence is from a dirty/untracked tree rather than a clean immutable candidate; no physical-device, 30-minute thermal, signed Android release AAB, complete iOS build/archive/TestFlight, public TLS/staging/production backend, final legal/privacy/asset, or store approval exists.

## Current surface and airtime normal requalification

The five-surface system, progressive fixed-cost Mud coating, standard-gravity airtime, slope-following presentation, chase-grade easing, optimized renderer, live/final exact classification, unusual-track catalog, exact screenshot-shaped Track Studio recovery, automatic grid/bridge placement, high-speed steering, structurally separated Studio controls, chase/cockpit correction, race telemetry/ranking UI, and private-room client hardening passed the current local normal gate on 2026-07-26. The older real-backend and extended-soak records below are retained as regression history, not protocol-3 proof; this does not substitute for a fresh one-shot immutable-candidate run or physical-phone qualification.

| Field | Current result |
|---|---|
| Full normal gate | `tools/qa/run_all_checks.sh`; `PASS all requested checks` |
| UTC | `20260725T192237Z` |
| Focused assertions | 4,706, all passed; plus 72/72 all-six AI finishers, 13 clean UI routes, 26 accessibility layouts, and source/editor/audio-playback checks |
| Full log | [`../evidence/logs/full-check-20260725T192237Z.log`](../evidence/logs/full-check-20260725T192237Z.log) |
| Log SHA-256 | `fac5a01f2c6db14d9a8c780e9fb735ccf52bb5325ac993615eb1a339f8dcba82` |
| Track/content | Track 440; smoothing 33; built-in benchmark 166; runtime 14; screenshot-shaped Studio 24; features 494; render 32; 3D track 71; scenery clearance 73; content/safe-area 1,146 |
| Formula/world | Formula car 81; camera 22; sparks 16; surface effects 48; 3D world 112 |
| Runtime systems | Persistence 364; audio 125 plus playback smoke; HUD 71; race authority/AI 700; race screen 78 |
| Private rooms | Network/protocol/fake/runtime 530; mobile lifecycle 29; product UI 37; local Nakama health endpoint passed |

### Current visual and dense-pack evidence

- Hands and sleeves remain above the cockpit body at center and full steering lock: [center](../evidence/screenshots/cockpit_hand_clearance_20260724/center00000010.png), [full right](../evidence/screenshots/cockpit_hand_clearance_20260724/full_right00000010.png), and [full left](../evidence/screenshots/cockpit_hand_clearance_20260724/full_left00000010.png).
- The four forward halo bars belong to a dedicated cockpit-only guard. Chase view hides that triangular frame while retaining the lower exterior rails; cockpit restores the guard without rebuilding the scene graph, and remote cars keep their full halo. Current chase proof is visible in all three surface captures below.
- The speedometer/telemetry cluster shows speed, gear, RPM, 16 rev LEDs, lap, sector, race time, shift/off-track state; the top-left ranking panel supports all 12 drivers, gaps, finish/DNF, player highlight, and immediate overtakes. Safe-area captures: [nearby cockpit](../evidence/screenshots/hud_mobile_final/nearby_cockpit_clear00000009.png), [wide](../evidence/screenshots/hud_mobile_final/wide_safe00000009.png), and [narrow](../evidence/screenshots/hud_mobile_final/narrow_safe00000009.png).
- The dimmer daylight grade keeps the scene clearly daytime without clipped sky/barriers. The opening venue now visibly includes patterned boards, two populated grandstands, and fence-safe stepped audience terraces: [reviewed chase frame](../evidence/screenshots/trackside_visual_qa_20260724_b/chase00000310.png).
- The current default catalog is visibly non-oval and uses six distinct archetypes—trident, crescent hammerhead, five-lobe crown, interlocking river knot, elevated figure-eight, and seven-apex rosette: [current six-circuit contact sheet](../evidence/screenshots/unusual_catalog_20260725/all_six_circuits.png).
- Bumpy asphalt shows irregular dark repairs, cracks, body dust and loose chips; gravel shows multiscale aggregate, tan vehicle dust, rounded stones and a dust plume. Mud now starts clean and progresses through a strong brown body, accents, wheels and ten instanced splatters. The current 65% progress capture reports 94.1% accumulation and 0.891 splatter opacity while the effect pool remains at one pass, 48 particles and 20 details: [current Mud proof](../evidence/screenshots/mud_optimized_20260726.png).
- The player flag keeps offline authority running. The overlay first shows exact completed times and `LIVE CLASSIFICATION • 5/12 COMPLETE`, then changes to the exact 12-driver final order with sharing enabled: [live](../evidence/screenshots/surface_results_camera_20260725/results-live.png) and [final](../evidence/screenshots/surface_results_camera_20260725/results-final.png).
- The chase camera's translation/yaw remain attached while road-grade pitch is eased. Focused abrupt 24-degree climb and 18-degree descent steps verify a bounded first frame, eventual convergence, and no position lag; cockpit presentation is unchanged.
- The Studio `DRAW TRACK` / `WORLD & ROAD` selector is visually separate from Undo/Redo, keeps 48 px touch targets, and the World tab exposes the road surface first: [current proof](../evidence/screenshots/road_surfaces_20260725/world_and_road.png). The old grid-position review page and MOVE GRID button no longer exist; the safest viable grid is selected automatically before the direct tour transition.

| Tier/view | Avg FPS | p95 | p99 | Max | Draws | Objects | Primitives | Evidence |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| Mobile Low chase | 59.8 | 19.67 ms | 20.50 ms | 21.82 ms | 220 | 558 | 258,726 | [`../evidence/logs/mobile_low_dense_chase_trackside_20260724.log`](../evidence/logs/mobile_low_dense_chase_trackside_20260724.log) |
| Mobile Low cockpit | 58.8 | 19.96 ms | 23.00 ms | 30.16 ms | 246 | 577 | 164,848 | [`../evidence/logs/mobile_low_dense_cockpit_trackside_20260724.log`](../evidence/logs/mobile_low_dense_cockpit_trackside_20260724.log) |
| Standard chase | 59.2 | 19.57 ms | 20.75 ms | 22.03 ms | 278 | 611 | 608,974 | [`../evidence/logs/standard_dense_chase_trackside_20260724.log`](../evidence/logs/standard_dense_chase_trackside_20260724.log) |
| Standard cockpit | 58.4 | 20.39 ms | 23.31 ms | 28.44 ms | 291 | 623 | 455,284 | [`../evidence/logs/standard_dense_cockpit_trackside_20260724.log`](../evidence/logs/standard_dense_cockpit_trackside_20260724.log) |

All four strict fixtures measured 660 frames with all 11 opponents within 30 m and passed average/p95/p99/max-frame limits. Mobile also stayed below the tightened 300-draw, 600-object, and 300,000-primitive ceilings. These are development-Mac host captures, not physical-device performance evidence.

Three current Mobile Low Mud stresses each measure 660 frames with all 11 opponents inside 30 m. They deliberately drive every player/remote dirt stage during the first 180 measured frames, then retain full coating. Results are 59.2–59.8 average FPS, 16.65–16.66 ms average frame, 17.55–17.65 ms p95, 17.71–17.84 ms p99, and 22.84–23.71 ms maximum, with 203 draws, 535 objects, and at most 250,342 primitives. [Run 1](../evidence/logs/mobile_low_mud_final_run1_20260726.log), [run 2](../evidence/logs/mobile_low_mud_final_run2_20260726.log), and [run 3](../evidence/logs/mobile_low_mud_final_run3_20260726.log). This proves bounded development-host behavior through coating transitions; physical-phone profiling remains open.

### Current built-in track geometry

Each built-in retains the reviewed 4.0–4.6 km authority target and 44–48 authority-unit width while replacing the earlier oval-like shapes. Saved/custom definitions remain hash-isolated; new Track Studio strokes use fixed 2200×1240 logical authority and a 1.8–5.2 km target range, so the same gesture produces byte-identical geometry on phone and desktop layouts.

| Track | Width | Physical width | Compiled authority length | Physical lap length |
|---|---:|---:|---:|---:|
| Evergreen Trident | 48 | 14.4 m | 3,999.921 | 1,199.976 m |
| Crescent Hammerhead | 46 | 13.8 m | 4,199.653 | 1,259.896 m |
| Northstar Crown | 46 | 13.8 m | 4,299.948 | 1,289.984 m |
| River Knot | 47 | 14.1 m | 4,099.627 | 1,229.888 m |
| Forest Crossing | 46 | 13.8 m | 4,599.896 | 1,379.969 m |
| Copper Rosette | 44 | 13.2 m | 4,399.972 | 1,319.992 m |

The catalog benchmark passed 166 assertions: six-track cold construction 475.893 ms, compile plus mobile mesh construction 2,858.724 ms, maximum single track 797.753 ms, 120 warm lookups 18.657 ms, maximum 767 samples/460 segments/5,520 triangles. The exact digitized 237-point screenshot silhouette passed deterministic recovery with 867 output samples and 18.422 minimum radius against 18.000 required. It used the first-choice one-neighbour local rounding pass, 6.689 maximum authority displacement, no harmonic projection, and byte-identical independent recompiles.

All six circuits were audited in both mobile and standard scenery tiers: zero runoff-clearance violations across 12 configurations, minimum clearance 0.508 m, worst barrier/fence skip 13.89%, and maximum venue construction 4,713.417 ms. A separate one-lap 12-car smoke finished 72/72 entries with zero DNF, invalid, non-finite, or stuck outcomes after the steering and surface calibration. Fast valid crests use a bounded 60 Hz ballistic state; grounded vehicle pitch follows sampled road grade with positive clearance, while airborne pitch follows flight velocity independently. Flat, low-speed, downhill, cross-deck, recovery, snapshot, interpolation, and legacy-network cases are covered by the race/network/world suites.

The high-speed rack endpoint moved only from 0.145 to 0.153 rad (8.31° to 8.77°) and the aerodynamic lateral coefficient from 0.00160 to 0.00168. Actual full-lock radius changes are 101.96→99.26 m at 220 speed, 123.58→119.65 m at 280, and 131.89→127.43 m at 310; low-speed steering, rack rate, gearing, and normalized controls are unchanged, while the top load remains within the existing 7.0 g gate at 6.93 g. A separate five-second launch fixture proves the surface authority ordering: smooth 188.58, weathered 140.44, bumpy 136.65, gravel 83.72, and mud 54.74 speed units.

## Current combined release-component evidence

The one-shot [`../evidence/logs/full-check-20260724T142719Z.log`](../evidence/logs/full-check-20260724T142719Z.log), SHA-256 `3727c0960a494ef71745cb8a72dbefe496fcb54e85ae63e6d67cd4d409194682`, is an informative non-PASS run. It passed every source/editor/game/UI/private-client check and all four representative plus 20 corpus AI correctness runs, but exited before backend stages because 2,075,104 ms exceeded the obsolete 900,000 ms wall gate. Coverage was not reduced: the gate was changed to a 2,700,000 ms absolute ceiling plus a normalized minimum of 1,100 authority vehicle-steps/s.

| Current component | Result | Evidence |
|---|---|---|
| Rebaselined schema-2 AI soak | PASS | [`../evidence/runtime/ai_soak_report.json`](../evidence/runtime/ai_soak_report.json), SHA-256 `aeb497dd8dc6b3c5e439eb03b14b6437e6f75f527923e90c8b45afa63abc2247`; 2,084,371 ms; 122,246 primary ticks; 2,933,904 twin authority vehicle-steps; 1,407.6 steps/s; 710.4 us/step |
| AI correctness and coverage | PASS | 4/4 representative 12-car × 20-lap runs and 20/20 corpus tracks; 288/288 car entries finished deterministically; zero DNF, invalid, non-finite, stuck, or recovery outcomes |
| Disposable real Nakama E2E | PASS | 102 assertions in the fresh console-observed rerun, including pre-sync ready refusal and real kick/rejoin ban |
| Twelve-client load | PASS | 1,011 assertions; [`../evidence/logs/nakama-12-client-load-20260724T154614Z.log`](../evidence/logs/nakama-12-client-load-20260724T154614Z.log), SHA-256 `e91055a45f4f2aa442db43ce659cfeff7978d099831f53a491d2640023bc386a` |
| Isolated PostgreSQL backup/restore | PASS | 12 checks; [`../evidence/logs/postgres-backup-restore-20260724T154648Z.log`](../evidence/logs/postgres-backup-restore-20260724T154648Z.log), SHA-256 `782bfd3907de2983f75766e7f856aba977f573f13f11862f867c5616695a7bde` |

All release components are therefore green in combined current evidence. This table is not a one-shot `--release` PASS log and must not be described as one; a clean immutable candidate still needs a fresh aggregate run.

## Historical frozen automated gate

```sh
tools/qa/run_all_checks.sh --release
```

| Field | Result |
|---|---|
| Timestamp | `20260723T214917Z` UTC (`2026-07-24 03:19:17` Asia/Kolkata) |
| Git base | `1034890142943b1f3bcf77a83c04ee0fa384d42b` |
| Tree | Dirty/untracked; this run is not clean-checkout or reproducibility proof |
| Engine | `4.7.1.stable.official.a13da4feb` |
| Exit/result | `0`; `PASS all requested checks` |
| Elapsed | 817 seconds |
| Full log | [`../evidence/logs/full-check-20260723T214917Z.log`](../evidence/logs/full-check-20260723T214917Z.log) |
| Log SHA-256 | `7be77897455026022b9554a20022fc37c7fc1bfd3fefafb1c881113e709215fc` |
| Checksum sidecar | `shasum -a 256 -c` returned `OK` |
| Whole-log audit | Zero `FAIL`, `WARNING`, `ERROR`, parse/compile fault, ObjectDB leak, or resource leak |

This gate predates the current mobile optimization, 2.5× built-in tracks, HUD/ranking, and private-room hardening. It remains useful regression history but is not the current candidate release result. The combined current results above cover every component, while a final clean immutable candidate must still rerun the aggregate gate in one shot.

## Automated suite results

| Suite | Result | Frozen observation |
|---|---|---|
| Asset inventory | PASS | 30 SVGs, 8 car colorways, 51 inventoried source/final/generated asset paths |
| Source/privacy/shell contracts | PASS | Source redaction, placeholder, privacy capability, credential-shape, JavaScript syntax, shell syntax, and shellcheck contracts passed |
| Godot editor parse | PASS | Project initialization and editor filesystem/class/plugin scan completed without parse/compile fault |
| Track domain | PASS | 169 assertions: stable RNG/fixed math 116, definition 27, compilation 26 |
| Track runtime | PASS | 14 assertions |
| Track features | PASS | 494 assertions |
| Track rendering | PASS | 23 deterministic presentation assertions |
| Content/safe areas | PASS | 172 assertions: catalog 96, offline configuration 30, safe area 5, Studio canvas 41 |
| Persistence/settings | PASS | 355 assertions: persistence/settings 337, portable profile exchange 18 |
| Audio | PASS | 14 deterministic WAV assets, 121 assertions, and playback smoke |
| Race authority/AI | PASS | 312 assertions: vehicle 36, laps 36, AI/director 107, input 12, bridge authority 58, recovery/release quality 63 |
| Race-screen integration | PASS | 56 assertions |
| Network/protocol/fake transport | PASS | 442 assertions: protocol 33, prediction/interpolation 29, fake room server 203, network race runtime 177 |
| UI routes | PASS | 13 routes—splash, home, Studio, tracks, tour, offline config/race, network race, saved, garage, settings, credits, multiplayer—with clean shutdown |
| Accessibility layouts | PASS | 15 fixtures at 1280×720, including 0.85/1.30 scale and cockpit/chase cases |
| Backend Compose | PASS | Pinned local Compose configuration validated |

The focused assertion total is 2,158, excluding the 13 route and 15 layout fixture counts, the asset/source/editor/audio-playback checks, the AI soak, and real-backend operational assertions.

## Current AI release soak

Report: schema-2 [`../evidence/runtime/ai_soak_report.json`](../evidence/runtime/ai_soak_report.json), SHA-256 `aeb497dd8dc6b3c5e439eb03b14b6437e6f75f527923e90c8b45afa63abc2247`.

| Gate/measurement | Current result |
|---|---|
| Coverage | PASS; four representative tracks at 12 cars × 20 laps plus 20/20 frozen corpus tracks, unchanged from the release contract |
| Outcomes | 288/288 car entries finished deterministically; zero DNF, invalid, non-finite, stuck, or recovery outcomes |
| Authority work | 122,246 primary fixed ticks; 2,933,904 twin authority vehicle-steps |
| Normalized host rate | 1,407.6 steps/s, above the frozen 1,100 minimum; 710.4 microseconds per step |
| Absolute host time | 2,084,371 ms, below the rebaselined 2,700,000 ms ceiling |

The absolute ceiling was changed only because the six built-ins are now 2.5× longer. The earlier 900,000 ms ceiling had been frozen against the shorter circuits and rejected the otherwise-correct one-shot at 2,075,104 ms. The new normalized rate prevents the larger absolute allowance from hiding a throughput regression, and the 20-lap/corpus coverage was not reduced.

For historical context, the pre-upgrade soak took 707,127 ms and its report snapshot had SHA-256 `0d81eb28cefd860be618288f5463894dcef2308b53a151f5ff78fce9c81bdd88`. That result applies only to the previous shorter built-ins; the schema-2 report above is current. Neither host soak proves rendered mobile FPS, memory, battery, or thermal behavior.

## Current private-room hardening

The private-room path now coalesces duplicate mobile pause/focus and resume/focus notifications into a single suspend/reconnect drive, guards stale asynchronous continuations with connection generations, and performs leave locally before best-effort server cleanup so the UI cannot hang on a dead transport. Android/iOS system Back from the lobby now executes the authoritative leave path before returning home.

Server and fake-server parity now enforce at most 12 control messages per second, reject ready outside `TRACK_SYNC`/`READY`, and make host kick terminal: the peer is removed from the match transport and its identity is banned from rejoining that room. Friendly client errors cover these cases.

| Current targeted suite | Result |
|---|---|
| Protocol/client/fake/runtime | PASS, 530 assertions: 45 + 36 + 225 + 224, including vertical airborne snapshot/prediction/interpolation/reconciliation coverage |
| Mobile lifecycle single-flight | PASS, 29 assertions including duplicate notifications, gated suspend/resume, stale completion, socket loss, local-first leave, and close-once |
| Private-room product UI | PASS, 37 assertions including system Back/leave |
| Disposable real Nakama E2E | PASS, 102 assertions including pre-sync ready refusal and real kick/rejoin ban |
| Current twelve-client load | PASS, 1,011 assertions; [`../evidence/logs/nakama-12-client-load-20260724T154614Z.log`](../evidence/logs/nakama-12-client-load-20260724T154614Z.log), SHA-256 `e91055a45f4f2aa442db43ce659cfeff7978d099831f53a491d2640023bc386a` |
| Current isolated PostgreSQL backup/restore | PASS, 12 checks; [`../evidence/logs/postgres-backup-restore-20260724T154648Z.log`](../evidence/logs/postgres-backup-restore-20260724T154648Z.log), SHA-256 `782bfd3907de2983f75766e7f856aba977f573f13f11862f867c5616695a7bde` |

This is a friends/private-room architecture, not a public matchmaking or anti-cheat service. The repository's Compose service binds loopback and no public TLS/WSS endpoint is configured; phones on the internet therefore cannot use the local proof as a production service. A managed endpoint/key configuration is still required. Room codes carry only about 30 bits and the rate limit is identity/node-local, so the design is not public-scale brute-force protection. The simulation host is trusted for snapshots and results and is not cheat-resistant.

## Historical real local backend results

The release gate used uniquely named disposable loopback Compose projects and removed their containers, networks, volumes, raw session responses, and database dumps. A final residual audit found zero RaceGlyph containers, networks, volumes, or related Godot/Nakama/PostgreSQL processes.

| Scenario | Result | Observation/evidence |
|---|---|---|
| Strict Nakama E2E | PASS | 85 assertions, zero failures/warnings/errors/ObjectDB/resource leaks; create/join/authority/track/readiness/race/reconnect/lifecycle coverage in the frozen runner |
| Twelve-client load | PASS | 1,011 assertions; 13 authentications, 12 admissions, one expected overflow refusal, 55 input relays, 33 snapshot deliveries, 4,633 ms |
| Load diagnostics | PASS | Godot errors/warnings, ObjectDB/resource leaks, backend errors, secret hits, and token hits all zero |
| Load evidence | PASS | [`../evidence/logs/nakama-12-client-load-20260723T220226Z.log`](../evidence/logs/nakama-12-client-load-20260723T220226Z.log), SHA-256 `fbc15f905fb3d8fd797ee542fe7b1a6a2a1493a3da3ee8309bdba1b8d47d60ac` |
| Isolated PostgreSQL restore | PASS | 12 checks; one source/restored user, one linked device, 19 migration rows, 48,475-byte backup, 25,549 ms; restored auth with `create=false` |
| Restore diagnostics | PASS | Service errors, secret/token hits, retained session responses, and retained dumps all zero |
| Restore evidence | PASS | [`../evidence/logs/postgres-backup-restore-20260723T220253Z.log`](../evidence/logs/postgres-backup-restore-20260723T220253Z.log), SHA-256 `119f5ac1886e3ded0bb9d146f1153f4689cf6078345f8a8a8fe909fe9a57caf9`; ephemeral backup SHA-256 `6d0ea6d84bc4b85148ede120bc84aa404c60628e0a00c8485a9aab3da05aac14` |

These are local functional drills, not staging/production TLS, distributed capacity, provider retention, encrypted off-site backup, or disaster-recovery proof.

## Closed pre-freeze regression

The first frozen attempt at `20260723T210944Z` functionally passed Nakama E2E 85/85, but [`../evidence/logs/full-check-20260723T210944Z.log`](../evidence/logs/full-check-20260723T210944Z.log) recorded `WARNING: 10 ObjectDB instances were leaked at exit` and `ERROR: 8 resources still in use at exit`. The global fatal scan rejected the run as intended. Log SHA-256: `c4a25b36896ee0e721f6b65d77d94af8b04b7d7e059be34718393a3e33ba2688`.

Verbose isolation found a cached `TrackDefinition` GDScript reference graph plus direct quit before asynchronous frame unwind; it did not implicate sockets, Nakama SDK/session nodes, or authentication material. The manifest validator was made runtime/cache-ignored, the fixture was runtime-loaded, references were explicitly released, shutdown was deferred, and the wrapper allowlist was removed. The final strict E2E and full-gate rerun are clean. This defect is closed and carries no waiver.

## Android candidate

| Check | Result | Observation/evidence |
|---|---|---|
| Current mobile-optimized APK static/signature audit | PASS | [`../builds/android/RaceGlyph-mobile-optimized.apk`](../builds/android/RaceGlyph-mobile-optimized.apk), 44,435,606 bytes, SHA-256 `536c14941a1a8d08fe73a514986f54da271b72b3dc56018ccc0cd1a50735e05b` |
| Manifest/config | PASS | `com.raceglyph.game`, version `0.2.0` (`2`), min API 24, target API 36, ARM64-only, exactly `INTERNET` + `VIBRATE`, debuggable with one signer, game/adaptive-icon metadata present |
| Shipping Vulkan APK on API 36 emulator | BLOCKED—EMULATOR GRAPHICS | Godot initialized, but both available SwiftShader and host-GPU AVD paths failed to present the Vulkan surface (`VkResult 5`) and terminated inside the emulator Vulkan stack. This is not recorded as an app runtime PASS |
| Temporary GL-compatibility smoke | PASS—non-shipping development observation | A separately exported, temporary GL-compat build rendered and navigated [menu](../evidence/screenshots/android_mobile_optimized_20260724/menu_gl_smoke.png), [offline setup](../evidence/screenshots/android_mobile_optimized_20260724/offline_setup_gl_smoke.png), [12-car race](../evidence/screenshots/android_mobile_optimized_20260724/race_12car_gl_smoke.png), and [active driving](../evidence/screenshots/android_mobile_optimized_20260724/race_driving_gl_smoke.png) to 184 km/h in gear 5. It does not qualify the shipping Vulkan APK |
| Release-signed AAB/Play | BLOCKED | No current release-signed AAB, protected owner keystore, Play signing/internal/pre-launch access, or submission-policy review is available |
| Physical Android matrix | BLOCKED | No hardware was attached; touch/controller/vibration/lifecycle/performance/thermal qualification is not claimed |

## iOS candidate

| Check | Result | Observation/evidence |
|---|---|---|
| Fresh unsigned Xcode project export | PASS | [`../builds/ios/mobile-optimized`](../builds/ios/mobile-optimized); current-source project-only export succeeded, and the temporary generation Team ID was scrubbed from source and generated output |
| Static project/plist/privacy/icon audit | PASS | `com.raceglyph.game`, `0.2.0` (`2`), iOS 15.0 deployment target, left/right landscape for iPhone+iPad, no sensitive usage-description keys, one privacy manifest with tracking false, 16/16 opaque icons including one 1024×1024 icon |
| Export evidence | PASS | [`../evidence/logs/ios-xcode-export-mobile-optimized-20260724T142020Z.log`](../evidence/logs/ios-xcode-export-mobile-optimized-20260724T142020Z.log), log SHA-256 `aac0642eb00de00063fe6127e9f74dac3f75ad1a5c2d1cbf4eb6de2322d5be75`; `RaceGlyph.pck` is 16,001,220 bytes, SHA-256 `ebf5d3f7f7f8ede05d9ec63f380617bb36256226c43c1b47c44970855b82747c` |
| No-sign host build | BLOCKED—HOST TOOLCHAIN | `xcodebuild` has no eligible destination: Any iOS Device is ineligible because the iOS 26.0 platform is not installed in Xcode Components |
| Signing/archive/TestFlight | BLOCKED | Owner team, certificate, provisioning profile, archive validation, and TestFlight access unavailable |
| Simulator/physical iPhone/iPad | BLOCKED | No eligible simulator/build destination or physical Apple device; touch/controller/haptics/lifecycle/performance/thermal evidence is not claimed |

## Visual, performance, privacy, and legal scope

| Gate | Result | Boundary |
|---|---|---|
| Deterministic rendering/source fixtures | PASS | Current normal gate: 32 track-rendering, 70 3D-track, 73 all-six scenery, 75 Formula-car, 22 camera, 16 sparks, 42 surface-effects, 111 3D-world, and 71 HUD assertions, plus 13 clean routes and 26 accessibility layouts |
| Captured development visuals | PASS—evidence capture only | Current captures cover hand clearance, chase culling, cockpit/chase HUD and safe areas; the Android captures are explicitly from the temporary non-shipping GL smoke build, not a shipping Vulkan runtime PASS |
| Frozen pixel-diff suite | NOT RUN | No candidate-wide thresholded visual-diff report is recorded |
| Current development-host AI/load gates | PASS—combined component evidence | Schema-2 full-coverage AI soak passed at 2,084,371 ms and 1,407.6 authority vehicle-steps/s; current 1,011-assertion relay load and 12-check restore passed. No new one-shot `--release` PASS is claimed |
| Mobile frame-time/memory/battery/thermal | BLOCKED | No representative physical-device profiler or 30-minute thermal evidence |
| Source privacy/redaction/credential contracts | PASS | Current normal source contract is clean; current Android/iOS metadata is audited as above |
| Public privacy/service/store audit | BLOCKED | No public network capture/provider schema/retention/TLS, backend self-service deletion, store disclosure, or owner-approved notice |
| Asset inventory/provenance structure | PASS | Current normal asset inventory/provenance contracts passed; official Nakama SDK license record remains present |
| Final identity/asset/legal clearance | BLOCKED | First-party/generated media remain `WIP`; final name/mark/similarity/rights and owner distribution approval remain open |
| Dependency vulnerability/SBOM review | NOT RUN | Pinning and notices exist; no final vulnerability/SBOM release report is claimed |

## Evidence rules

Every future result records timestamp/timezone, exact commit/build and dirty state, command/manual script, environment/device, seed and track hash where applicable, exit status, counts/duration, evidence path/checksum, unresolved defects, and reviewer. Preserve raw logs/captures under the repository evidence policy.

Allowed outcomes are `PASS`, `FAIL`, `BLOCKED`, and `NOT RUN`. Qualifiers such as “development observation” narrow a PASS; they never promote emulator/export evidence to physical or store evidence. A project parse alone is not gameplay, network, mobile, visual, or performance validation.

Critical/high defects block release. A fix requires targeted regression plus the relevant broader suite; deleting or weakening a failing test does not close the defect.

## Remaining release evidence

- Clean immutable checkout/tag and reproducible signed rebuild, followed by the full gate on that exact tree.
- Exact owner-approved name, reverse-DNS IDs, version/support floors, territories, age/content decisions, privacy/legal text, complete asset clearance, dependency/SBOM security review, and store/support package.
- Release-signed Android AAB plus Play internal/pre-launch and physical Android matrix.
- Usable iOS platform, complete build/sign/archive/TestFlight, and physical iPhone/iPad matrix.
- Physical touch/controller/haptics/lifecycle checks, 60/30 FPS frame-time and memory profiles, worst-case twelve-car/forest/bridge captures, and 30-minute thermal/battery runs.
- Approved public provider/region/TLS/DNS/secrets/monitoring/retention/deletion/budget, encrypted off-site backup/restore objectives, staging smoke, and production authorization.
- Cross-functional evidence review and explicit owner GO. Until then, the release decision remains NO-GO.
