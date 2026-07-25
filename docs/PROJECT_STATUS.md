# Project Status

Last updated: 2026-07-26 (Asia/Kolkata)

## Goal

Deliver the original premium-quality Godot 4 draw-to-race game defined by:

- `/Users/sabarim/Downloads/CODEX_2D_COMPLETE_MASTER_PLAN.md`
- `/Users/sabarim/Downloads/CODEX_2D_AUTONOMOUS_GOAL_PROMPT.md`

The earlier local candidate reached the autonomous contract's original stopping boundary. The premium true-3D presentation and mobile-quality revisions now include complex-track recovery, six unusual default circuits, five deterministic road surfaces with car coating and moving effects, gravity-driven crest airtime, fixed world-space track/scenery, moving Formula cars, corrected cockpit hands, smoothed chase bridge transitions, optimized dense-car rendering, a controlled daytime grade, populated trackside venues, a full telemetry/ranking HUD, live post-finish classification, mobile-safe Track Studio, and hardened private rooms.

## Current phase

**The chase/slope, surface-effects, and automatic Track Studio revision passes the complete normal local gate. A fresh one-shot immutable-candidate release gate, protocol-3 backend component requalification, and physical-device qualification remain open.**

This wording is deliberate. “Feature-complete” applies to the implemented v1 game and local backend scope. It does not mean store-ready, physically qualified, signed, publicly hosted, legally cleared, tagged, or reproducible from a clean checkout.

## Current mobile-quality requalification

- Current source is version `0.3.0`, protocol `3`, track schema `2`, and generator `3`. It adds smooth, weathered, bumpy, gravel, and mud profiles to Track Studio and the predefined catalog. Drive efficiency, speed drag, grip, braking, rolling resistance, AI pace, grounded suspension response, road texture, car coating, rain/spray, and loose road detail share one deterministic style. A five-second authority proof reaches 188.58/140.44/136.65/83.72/54.74 speed units respectively, so the selection creates a large verified performance difference. Mud now starts clean and progressively turns the player body, accents and wheels brown across ten bounded stages. Mobile opponents use three tint stages with no splatter node, while one player coating draw, one 12-particle rear wake, and 20 static details retain the visible effect.
- The exact 160 mph crest fixture now launches at 4.600 m/s, remains airborne for 1.683 seconds, reaches 7.033 m maximum road clearance, and lands exactly under standard gravity. Tyre acceleration, braking, steering, and rolling forces do not act while airborne.
- Full normal gate: `PASS all requested checks`; 4,706 focused assertions plus a six-circuit/72-car finish smoke, 13 clean UI routes, 26 accessibility layouts, and source/editor/audio-playback checks. Evidence: [`../evidence/logs/full-check-20260725T192237Z.log`](../evidence/logs/full-check-20260725T192237Z.log), SHA-256 `fac5a01f2c6db14d9a8c780e9fb735ccf52bb5325ac993615eb1a339f8dcba82`.
- Fresh visual review proves that bumpy asphalt uses irregular repairs/cracks, body dust and loose chips; gravel uses multiscale aggregate, tan vehicle dust, rounded stones and a dust plume; and Mud reaches 94.1% accumulation with all ten player splatter instances, 0.891 opacity, a strongly browned body/wheel finish, one rear wake, 48 pooled particles, and 20 road details: [current Mud capture](../evidence/screenshots/mud_optimized_20260726.png). Weathered asphalt retains its wet film, light rain and mist.

- Previous pre-correction surface/airtime gate: `PASS all requested checks`; 4,595 focused assertions plus its six-circuit/72-car finish smoke, 13 clean UI routes, 26 accessibility layouts, and source/editor/audio-playback checks. Evidence: [`../evidence/logs/full-check-20260725T084620Z.log`](../evidence/logs/full-check-20260725T084620Z.log), SHA-256 `b17b004352b773bf6a430ef1d7190378ef6b5c60db477d81a7a9d21f96114fb0`.
- The default catalog now ships six visibly different layouts: Evergreen Trident, Crescent Hammerhead, Northstar Crown, River Knot, Forest Crossing, and Copper Rosette. The all-six 12-car smoke finished 72/72 cars with zero DNF, invalid, non-finite, or stuck outcomes. [Catalog contact sheet](../evidence/screenshots/unusual_catalog_20260725/all_six_circuits.png).
- Track Studio repairs the exact digitized 237-point screenshot silhouette into 867 finite race samples with 18.422 minimum radius against 18.000 required. The first-choice repair touches only an unsafe point and one neighbour, records 6.689 authority units maximum displacement, and uses no harmonic projection. Two independent compiles are byte-identical; clean crossings become safe bridges automatically, while non-finite input still fails safely.
- Fast rising ramps launch only at a real crest transition and follow a bounded 60 Hz standard-gravity arc before an exact grounded landing. Flat, low-speed, downhill, unrelated-bridge, recovery, prediction, interpolation, and legacy-network cases have explicit regression coverage.
- High-speed steering received a deliberately small real-authority increase: the full-lock physical radius changes from 101.96 m to 99.26 m at 220 authority speed and from 123.58 m to 119.65 m at 280, while low-speed lock, rack rate, gearing, input contracts, and deterministic AI/network behavior remain unchanged.
- Track Studio uses fixed 2200×1240 logical authoring authority regardless of phone control size and maps custom loops into a longer 1.8–5.2 km target range. `DRAW TRACK` and `WORLD & ROAD` are separate 48 px tabs above clipped content; the latter begins with the road-surface selector and its live description. Both modes pass at 1280×720 and notched 960×540 for 0.85×, 1.0×, and 1.3× UI scales. The manual grid-position review page is removed: BUILD CIRCUIT deterministically selects the safest viable grid and continues directly to the tour. `SNAP GAP CLOSED` remains directly above `LOAD DEMO LOOP`, and the obsolete tour restart action is removed. [Current World & Road proof](../evidence/screenshots/road_surfaces_20260725/world_and_road.png).
- All six circuits pass topology-aware scenery clearance in both mobile and standard tiers: zero violations across 12 configurations, at least 0.500 m clearance, at least 89.55% barrier/fence retention, and bounded venue construction. The local Nakama health endpoint also passed after the private-room client/UI suites.
- Strict dense 12-car host fixtures kept all 11 opponents within 30 m. Mobile Low chase/cockpit measured 59.8/58.8 average FPS and 19.67/19.96 ms p95; Standard chase/cockpit measured 59.2/58.4 FPS and 19.57/20.39 ms p95. All four also passed p99 and maximum-frame gates. Exact draw/object/primitive counts and logs are in [`PERFORMANCE.md`](PERFORMANCE.md).
- Three stricter Mobile Low Mud runs kept all 11 opponents inside 30 m and stepped the full field through every dirt stage inside the measured window. They hold 59.2–59.8 average FPS, 17.55–17.65 ms p95, 17.71–17.84 ms p99, and 22.84–23.71 ms maximum, with no recurring 30 FPS-class stall. Evidence: [run 1](../evidence/logs/mobile_low_mud_final_run1_20260726.log), [run 2](../evidence/logs/mobile_low_mud_final_run2_20260726.log), and [run 3](../evidence/logs/mobile_low_mud_final_run3_20260726.log).
- The environment now uses a dimmer filmic daytime grade. Mobile Low retains 18 original patterned boards, six grandstands, four grounded audience terraces, and 160 spectators; Standard uses 48 boards, nine stands, four terraces, and 384 spectators. Vegetation is spatially batched and the crowd/board layer has no shadows, colliders, skeletons, animation graphs, or per-frame scripts. Reviewed frame: [opening venue](../evidence/screenshots/trackside_visual_qa_20260724_b/chase00000310.png).
- Cockpit hands and sleeves clear the body at full steering lock. The four forward halo bars are now a cockpit-only guard: chase view hides the odd triangular frame while retaining exterior cockpit rails, and cockpit restores the full guard synchronously. Remote cars retain their complete silhouette. Evidence: [center](../evidence/screenshots/cockpit_hand_clearance_20260724/center00000010.png), [full right](../evidence/screenshots/cockpit_hand_clearance_20260724/full_right00000010.png), [full left](../evidence/screenshots/cockpit_hand_clearance_20260724/full_left00000010.png), and the current road-surface chase captures above.
- Grounded cars now derive pitch from forward/back road probes (bounded to 28 degrees), retain ride clearance, and follow genuine slopes without entering the mesh. Once airborne, pitch comes from the ballistic velocity rather than the road grade, so a car remains visually and physically independent until its exact landing.
- Chase translation and yaw stay immediately attached to the car while bridge-grade pitch alone is eased at 4.2/s and capped at 42 degrees/s. Abrupt 24-degree climb and 18-degree descent fixtures prove a soft first-frame response, convergence, and zero world-position lag; cockpit behavior is unchanged.
- Finishing no longer freezes offline authority. Remaining AI keep racing and the result overlay changes from `LIVE CLASSIFICATION • x/12 COMPLETE` to `FULL CLASSIFICATION • 12 DRIVERS`, filling every exact finish time as it arrives and enabling sharing only after the field is terminal: [live](../evidence/screenshots/surface_results_camera_20260725/results-live.png) and [final](../evidence/screenshots/surface_results_camera_20260725/results-final.png).
- Current release components are all green in combined evidence. The one-shot [`../evidence/logs/full-check-20260724T142719Z.log`](../evidence/logs/full-check-20260724T142719Z.log), SHA-256 `3727c0960a494ef71745cb8a72dbefe496fcb54e85ae63e6d67cd4d409194682`, passed every pre-soak check and all AI correctness, then stopped solely because 2,075,104 ms exceeded the obsolete 900,000 ms host wall gate inherited from the shorter tracks.
- Coverage was not reduced. The rebaselined schema-2 [`../evidence/runtime/ai_soak_report.json`](../evidence/runtime/ai_soak_report.json), SHA-256 `aeb497dd8dc6b3c5e439eb03b14b6437e6f75f527923e90c8b45afa63abc2247`, passed in 2,084,371 ms under a 2,700,000 ms ceiling and at 1,407.6 authority vehicle-steps/s above the 1,100 minimum: 122,246 primary ticks, 2,933,904 twin vehicle-steps, 4/4 representative runs, 20/20 corpus tracks, 288/288 car entries finished deterministically, and zero DNF/invalid/non-finite/stuck/recovery outcomes.
- Current backend component reruns passed: real Nakama E2E 102 assertions; 12-client load 1,011 assertions ([log](../evidence/logs/nakama-12-client-load-20260724T154614Z.log), SHA-256 `e91055a45f4f2aa442db43ce659cfeff7978d099831f53a491d2640023bc386a`); isolated PostgreSQL backup/restore 12 checks ([log](../evidence/logs/postgres-backup-restore-20260724T154648Z.log), SHA-256 `782bfd3907de2983f75766e7f856aba977f573f13f11862f867c5616695a7bde`). This combined record is not misrepresented as a new one-shot `--release` PASS.

## Completed implementation

- Complete Track Studio loop: draw, guide, undo/redo/clear, validate, very-local complex-stroke rounding, automatic safe grid/bridge placement, direct generation/tour, save/reload/edit/export/delete, fixed logical mobile authority, and room-return authoring.
- Deterministic track schema/compiler/runtime with canonical hashes, migrations, malformed-input limits, six unusual predefined archetypes, bridges, pits, grid/checkpoints/lanes, minimap, recovery data, and seeded forest presentation. Every built-in retains the reviewed 4.0–4.6 km authority length and 44–48 authority-unit width while replacing the old oval-like geometry; saved/custom track hashes remain isolated.
- Offline race for one player plus 1–11 AI, conventional controls and assists, collisions/recovery, physically bounded crest airtime, cockpit/chase cameras, pause/results, graphics modes, effects, haptics hooks, and category audio. The responsive race HUD includes speed, gear, RPM, shift LEDs, lap/sector/time and a live 12-driver ranking/gap/finish panel in offline and private races; offline results continue through every remaining AI finisher and retain exact times for the full field.
- True world-space 3D race presentation with generated surface-specific road/runoff/kerbs/markings, bounded rain/spray/loose-detail effects, grounded terrain, deterministic patterned billboards, populated grandstands/terraces, a controlled daylight environment, moving/interpolated and grade-aligned 12-car grid, animated Formula drivetrain/steering detail, corrected cockpit hand clearance, cockpit-only halo guard, fixed scenery roots, shared remote-car body/wheel draws, spatial vegetation/crowd batching, distance LOD, and chase-only cockpit-detail culling.
- Deterministic AI personalities/tactics/recovery plus representative 20-lap and frozen generated-corpus soak coverage.
- Responsive safe-area application shell with 13 routes, accessibility settings/layout fixtures, original identity foundation, eight fictional colorways, credits, and notices.
- Versioned persistence with atomic writes, backups, corruption recovery, migrations, portable local export, and complete local deletion/session clearing.
- Private human-only rooms for up to 12 players through pinned Nakama/PostgreSQL: create/join, lock/ready/start, circuit/schema/hash verification, same-room Studio, roster/rules, prediction/relay, reconnect, host transition, results/share/rematch, and offline outage behavior. Mobile pause/focus is single-flight, stale reconnect work is generation-guarded, leave is local-first, system Back leaves authoritatively, ready is phase-gated, control traffic is limited to 12/s, and kick removes plus bans room rejoin.
- Disposable local backend health/E2E/load and isolated backup/restore drills with retained redacted evidence and teardown audits.
- Fresh current-source mobile artifacts as far as local tooling allows: statically verified Android APK and unsigned iOS Xcode project. Android shipping Vulkan runtime and iOS build/sign destinations remain externally blocked as detailed below.

Private-room AI fill, ranked/public matchmaking, chat/economy/ads, strong anti-cheat, and public deployment are explicit v1 exclusions, not missing features.

The tested private-room backend is local/loopback only. A public TLS/WSS deployment plus managed mobile endpoint/key is still required before internet-connected phones can join. The approximately 30-bit friend code and identity/node-local rate limit are appropriate to the private-friends scope, not public-scale brute-force protection, and the race host remains trusted for snapshots/results rather than cheat-resistant.

## Superseded frozen verification baseline

The following gate remains useful regression history for the pre-3D candidate, but it predates the current renderer, 3D assets, Mobile rendering backend, and new presentation tests. It is not current release evidence. Current component evidence is summarized above; a future clean immutable candidate still needs a fresh one-shot aggregate gate.

The authoritative gate was:

```sh
tools/qa/run_all_checks.sh --release
```

| Field | Frozen value |
|---|---|
| Start | `20260723T214917Z` UTC (`2026-07-24 03:19:17` Asia/Kolkata) |
| Git base | `1034890142943b1f3bcf77a83c04ee0fa384d42b` |
| Tree state | Dirty/untracked; therefore not clean-checkout or reproducibility evidence |
| Result | `PASS all requested checks`, exit `0` |
| Elapsed | 817 seconds |
| Log | [`../evidence/logs/full-check-20260723T214917Z.log`](../evidence/logs/full-check-20260723T214917Z.log) |
| Log SHA-256 | `7be77897455026022b9554a20022fc37c7fc1bfd3fefafb1c881113e709215fc` |
| Strict audit | Zero `FAIL`, `WARNING`, `ERROR`, parse/compile fault, ObjectDB leak, or resource leak |

High-level results:

- 30 SVGs, 8 car colorways, and 51 inventoried source/final/generated asset paths validated.
- 2,158 focused game/network assertions passed, plus audio playback, 13 clean UI routes, and 15 accessibility layout fixtures.
- AI: four representative 12-car × 20-lap runs and 20/20 frozen corpus tracks passed deterministically with zero DNF, invalid, non-finite, or stuck outcomes; aggregate development-host time was 707,127 ms.
- Real local Nakama: 85 strict E2E assertions and a 1,011-assertion 12-client load passed; the thirteenth authentication produced the one expected overflow refusal.
- PostgreSQL: 12 restore checks, 19 migrations, and restored account/device authentication passed against disposable isolated volumes.
- Teardown audit: zero RaceGlyph containers, networks, volumes, or related residual processes.

The detailed count, checksums, mobile audits, and scope limitations are in [`TEST_REPORT.md`](TEST_REPORT.md).

## Mobile candidate state

### Android

The current [`../builds/android/RaceGlyph-mobile-optimized.apk`](../builds/android/RaceGlyph-mobile-optimized.apk), SHA-256 `536c14941a1a8d08fe73a514986f54da271b72b3dc56018ccc0cd1a50735e05b`, passed static/signature audit. It is `com.raceglyph.game` version `0.2.0` (`2`), ARM64-only, minimum API 24, target API 36, requests exactly `INTERNET` and `VIBRATE`, and is debuggable with one signer.

The shipping Vulkan APK could not present its surface in the API 36 AVD under either available SwiftShader or host-GPU backend and terminated in the emulator Vulkan stack. It is not recorded as a runtime PASS. A temporary **non-shipping GL-compatibility build** did navigate menu/setup/12-car race and drive to 184 km/h in gear 5; screenshots are indexed in [`TEST_REPORT.md`](TEST_REPORT.md). No current release-signed AAB, Play result, physical-device performance, or thermal proof exists.

### iOS

The fresh unsigned Xcode export at [`../builds/ios/mobile-optimized`](../builds/ios/mobile-optimized) passed project/plist/privacy/icon audit: `com.raceglyph.game` version `0.2.0` (`2`), iOS 15.0 deployment target, both landscape orientations for phone/tablet, no sensitive usage-description keys, privacy tracking false, and 16/16 opaque icons including 1024×1024. `RaceGlyph.pck` SHA-256 is `ebf5d3f7f7f8ede05d9ec63f380617bb36256226c43c1b47c44970855b82747c`; evidence is [`../evidence/logs/ios-xcode-export-mobile-optimized-20260724T142020Z.log`](../evidence/logs/ios-xcode-export-mobile-optimized-20260724T142020Z.log).

No eligible build destination exists because the iOS 26.0 platform component is not installed. Source and generated Team IDs are empty after temporary generation data was scrubbed. An installed usable platform, owner Apple team/certificate/profile, archive validation, TestFlight, and physical iPhone/iPad tests remain open.

## Closed regression

The first frozen attempt, [`../evidence/logs/full-check-20260723T210944Z.log`](../evidence/logs/full-check-20260723T210944Z.log), passed the real Nakama E2E assertions 85/85 but was correctly rejected by the global fatal scan because shutdown emitted `10 ObjectDB instances were leaked` and `8 resources still in use`. Verbose isolation traced the retained graph to cached `TrackDefinition` script references plus quitting before an asynchronous frame unwind—not sockets, SDK sessions, or auth material.

The runtime manifest validator/fixture loading and shutdown release sequence were corrected, the old allowlist was removed, and the final strict E2E plus whole-gate regression is clean. This is a closed defect, not an open candidate exception.

## Known defects

- No Critical or High defect is open in the tested local/automated scope.
- No warning, error, ObjectDB leak, or resource leak is waived in the current normal gate.
- Every current release component is green in combined evidence, but no new one-shot aggregate `--release` PASS log exists; the non-PASS one-shot and subsequent component reruns must remain distinguishable.
- Unqualified external release gates below are limitations/blockers, not evidence that they passed.

## External blockers and owner decisions

- Clean checkout, immutable release commit/tag, reproducible rebuild, and final evidence re-run from that exact tree.
- Representative Android/iPhone/iPad hardware, full touch/controller/haptics/lifecycle matrix, frame-time/memory profiling, and 30-minute battery/thermal runs.
- Owner-approved final name/trademark/domain, reverse-DNS IDs, version/support floors, territories, age/content decisions, privacy/legal text, asset clearance, support plan, and store metadata.
- Owner-controlled Android release keystore and Play signing/internal/pre-launch/store access.
- Usable local iOS platform plus owner Apple team, certificate, provisioning, archive validation, TestFlight, and physical devices.
- Public provider/region, TLS/WSS, DNS, secret custody, monitoring, retention/deletion, budget, encrypted off-site backup, restore objectives, staging, and production authorization.
- Final dependency/security/SBOM review and store-policy review at submission time.

## Next checkpoint

The current soak/load/restore components are complete and green. The next valid checkpoint is owner-assisted release preparation:

1. Approve the final identity, package/bundle IDs, support floors, legal/privacy/asset decisions, and release scope.
2. Supply/authorize signing identities and representative physical devices; repair/install the usable iOS platform component.
3. Freeze a clean immutable candidate, rebuild signed artifacts, and rerun the complete gate in one shot against that exact commit.
4. Complete physical performance/thermal, staging/public-service, store, and cross-functional GO/NO-GO evidence without weakening any existing gate.
