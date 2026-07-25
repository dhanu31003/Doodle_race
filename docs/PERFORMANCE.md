# Performance Plan

Status: **mobile-quality optimization and every release component are green in combined development-host evidence; physical-device qualification remains open**. Bounded render/effect paths, 60/30 FPS modes, mobile render budgets, dense twelve-car telemetry, deterministic AI-soak telemetry, and a local 12-client relay-load harness exist. The current normal QA, dense-pack fixtures, rebaselined full-coverage AI soak, real Nakama E2E/load, and PostgreSQL restore checks pass as summarized below and in `TEST_REPORT.md`. There is no new one-shot `--release` PASS log: the one-shot run stopped only on the obsolete pre-lengthening wall-clock gate, and the corrected soak plus backend components were then rerun separately. No physical-device frame-time, memory, battery, or thermal gate is claimed.

## User-facing targets

- 60 FPS on the primary modern supported tier (`16.67 ms` frame budget).
- Stable 30 FPS fallback on the older supported tier (`33.33 ms`).
- No visible shader compilation, resource loading, or save/network hitch during a race.
- Stable 30-minute thermal behavior on physical devices.
- Bounded memory, particles, skid marks, labels, audio voices, snapshots, and logs.

Release support floors and memory caps are set only after physical-device measurements. Emulator/simulator results can diagnose but cannot prove release performance.

## Current true-3D target-Mac result

The normal macOS display-driver fixture on the target Apple M2 at 1280×720 discarded 180 racing frames for warm-up and measured 660 frames of the dense twelve-car true-3D scene. It recorded 60.0 average FPS, 16.66 ms average and 17.33 ms p95 wall-frame time, 14.66 ms average process time, 0.02 ms average physics time, 360 peak draw calls, 446 peak rendered objects, and 607,416 peak primitives. The run also proved 47.60 m of player travel while track and scenery roots remained at identity.

Evidence: [`../evidence/logs/visual-motion-performance-20260724T092900Z.log`](../evidence/logs/visual-motion-performance-20260724T092900Z.log), SHA-256 `022b3518938d2bb555feb96a3fea3275186c01da38ed04d037ea7533c70f55c1`. This clears the development-Mac visual gate; it is not a physical Android/iOS thermal or battery result.

## Mandatory worst cases

1. Twelve-car starting grid and first corner with collision/effects/HUD.
2. Dense forest decoration at the widest and closest supported camera views.
3. Valid bridge crossing with both layers occupied, shadows, occlusion, and collision filtering.
4. Twenty-lap 12-car AI soak.
5. Twelve-peer multiplayer snapshot/input load under target RTT, jitter, and loss.
6. Background/resume and asset/save activity around scene transitions—not during active racing.

## Provisional 60 FPS allocation

| Area | Target p95 | Notes |
|---|---:|---|
| Vehicle, race, collision | 3.0 ms | fixed step; all cars |
| AI decisions/navigation | 2.5 ms | bounded queries; stagger only if behavior remains valid |
| World rendering/effects | 5.0 ms | includes bridge/decor |
| UI/camera/audio submission | 1.5 ms | no layout churn |
| Network/serialization | 1.0 ms | multiplayer case |
| Engine/platform/headroom | 3.67 ms | guards spikes/thermal drift |

These are engineering allocations, not measurements. The Godot profiler and platform tools decide whether they are realistic.

## Design controls

- Reuse 3D meshes/materials; measure repeated scenery as ordinary instances versus MultiMesh and keep only the faster measured path.
- View/zoom culling and animation LOD; no processing nodes for every tree/crowd card.
- Pool transient effects/labels; ring buffers for skid marks, diagnostics, replay frames, and snapshots.
- Preload/warm race-critical shaders/resources before countdown.
- Keep track generation off the active-race path; perform plain-data work on workers only where thread-safe.
- Spatially partition cars/decor and bound AI neighbour/collision queries.
- Avoid per-frame allocations, string formatting, signal churn, texture creation, and unbounded arrays.
- Rate-limit correction effects, haptics, audio voices, and telemetry.

## Implemented quality tiers

Normal mode caps the engine at 60 FPS; Battery Saver caps it at 30 FPS. Low Graphics mode increases generated-track sample spacing, halves the 3D viewport resolution, reduces trackside instances and shadow distance, disables fog/antialiasing, and suppresses transient cosmetic effects. Both camera mounts and their FOV are speed-invariant in every accessibility mode, so acceleration, suspension heave, and gear changes cannot pull the horizon down; the chase mount separately eases only bridge-grade pitch while translation and yaw stay attached. Reduced Motion still sharpens camera response and suppresses other presentation motion. These settings do not alter authoritative physics, track geometry, checkpoint visibility, collision fairness, or multiplayer compatibility.

The mobile tier now also bounds built-in track generation to at most 460 mesh segments and 5,520 triangles, coarsens trackside barrier/fence cadence, and caps distance-driven detail. Remote Formula cars share a single authored-body `ArrayMesh` draw and render their four wheels through one `MultiMesh` draw. Mobile-born opponents keep the staged brown body/wheel tint but allocate no splatter geometry; the focused ceiling is 21 nodes and six meshes versus the locally controlled high-detail car's 150 nodes and 126 meshes. Remote shadows are disabled, while the player's visual quality remains intact.

Road weather/debris is fixed-cost presentation: one rain field, one static loose-detail `MultiMesh`, one player coating draw, and four preallocated spray emitters. Mobile Mud activates one rear wake, uses 12 particles per emitter (48 total pool capacity), one clod pass, half-rate binding, and at most 20 static details. Its shader uses two arithmetic soil fields with no procedural hash/noise/sine and skips the normal-map sample. Player dirt uses ten quantized stages and an alpha-zero prewarm instance; mobile opponents use three tint stages, no splatter node, no cosmetic rain-light pulse writes, and evenly split wheel/suspension/material updates across two frames. Bringing the full grid together performs no effect allocation.

The populated venue layer remains presentation-only and deterministic. Mobile Low keeps 18 patterned original billboards, six licensed low-poly grandstands, four grounded viewing terraces, and 160 project-authored spectators; Standard keeps 48 boards, nine stands, four terraces, and 384 spectators. Crowd, terrace, and billboard shadows are disabled, and the layer has no colliders, skeletons, animation players, or per-frame scripts. Mobile trees/bushes were reduced from 52 imported render graphs to at most 12 tight spatial batches. Standard uses a finer 3x3 vegetation grid so its denser forest does not submit an entire track quadrant when only one tree is visible.

Cockpit-only interior microdetails are visibility-switched rather than rebuilt. The four forward halo bars are grouped in a dedicated cockpit guard: chase hides the odd triangular frame while keeping the lower exterior rails, cockpit restores the complete guard synchronously, and remote cars keep their full silhouette. The driver's hands and sleeves were raised and constrained above a conservative cockpit-floor guard through full left/right steering lock, eliminating the body intersection shown in the original report.

The start grid uses a nine-authority-unit stagger pitch, yielding 18 units between same-lane cars against the 16-unit collision capsule. The 12-car first collision pass now performs 66 checks with zero resolutions and zero maximum penetration, removing the avoidable spawn-overlap hitch. The race HUD is retained at full UI resolution even when the 3D viewport is halved; its speed/RPM/gear/sector telemetry avoids 60 Hz formatted-string churn, and the standings panel is capped at 10 Hz.

## Current dense twelve-car host captures

The strict fixture holds all 11 opponents within 30 m of the player for 660 measured frames after warm-up. The current frozen host thresholds are average FPS at least 55, p95 at most 20.5 ms, p99 at most 33.3 ms, and maximum post-warm-up frame at most 50 ms. Mobile additionally caps 300 draws, 600 objects, and 300,000 primitives; Standard caps 650 draws, 1,000 objects, and 850,000 primitives. The host-throughput command uses `--disable-vsync` so display refresh quantization cannot turn a small timing change into an artificial half-refresh result; shipped gameplay VSync is unchanged.

| Tier/view | Avg FPS | p95 | p99 | Max frame | Draws | Objects | Primitives | Evidence |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| Mobile Low, chase with cockpit culled | 59.8 | 19.67 ms | 20.50 ms | 21.82 ms | 220 | 558 | 258,726 | [`../evidence/logs/mobile_low_dense_chase_trackside_20260724.log`](../evidence/logs/mobile_low_dense_chase_trackside_20260724.log) |
| Mobile Low, cockpit restored | 58.8 | 19.96 ms | 23.00 ms | 30.16 ms | 246 | 577 | 164,848 | [`../evidence/logs/mobile_low_dense_cockpit_trackside_20260724.log`](../evidence/logs/mobile_low_dense_cockpit_trackside_20260724.log) |
| Standard, chase | 59.2 | 19.57 ms | 20.75 ms | 22.03 ms | 278 | 611 | 608,974 | [`../evidence/logs/standard_dense_chase_trackside_20260724.log`](../evidence/logs/standard_dense_chase_trackside_20260724.log) |
| Standard, cockpit | 58.4 | 20.39 ms | 23.31 ms | 28.44 ms | 291 | 623 | 455,284 | [`../evidence/logs/standard_dense_cockpit_trackside_20260724.log`](../evidence/logs/standard_dense_cockpit_trackside_20260724.log) |

All four current populated-trackside runs pass the frozen frame-time, density, p99/max-spike, and structural ceilings. These are macOS development-host measurements, not Android/iOS device results.

The current effect-heaviest Mobile Low reruns use muddy River Knot and hold all 11 opponents inside 30 m for 660 measured frames. Unlike the earlier static fixture, the timer includes forcing the complete field through every dirt-stage transition during the first 180 measured frames and retains the fully muddy state afterwards. Three passes record 59.2–59.8 average FPS, 16.65–16.66 ms average frame time, 17.55–17.65 ms p95, 17.71–17.84 ms p99, and 22.84–23.71 ms maximum. Peak scene cost stays at 203 draws, 535 objects, and 229,552–250,342 primitives, beneath the strict 300/600/300,000 Mobile ceilings. No recurring long frame or 30 FPS-class stall appears on the Apple M2 host; physical Android/iOS thermal qualification remains separate.

Evidence: [run 1](../evidence/logs/mobile_low_mud_final_run1_20260726.log), SHA-256 `396952cf4f02ad1a7c026b244efd4c00bf90546952f7cd48a15ad5f81cc2d312`; [run 2](../evidence/logs/mobile_low_mud_final_run2_20260726.log), SHA-256 `23d8a7ff695917d9b133f6e44f1808e8e38b3d81100abe0e5ce95ad7f29985b2`; [run 3](../evidence/logs/mobile_low_mud_final_run3_20260726.log), SHA-256 `601f51d95e08e5f65fa4d448656b6861bb11fc8c4163b439a216056aaaaa2d9c`.

## Longer/wider built-in track cost

All six built-ins are exactly 2.5 times their previous authority length and 12 authority units wider. Physical lap lengths now range from 1,199.976 m to 1,379.969 m and widths from 13.2 m to 14.4 m. The current normal gate recorded six-track cold construction in 475.893 ms, compile plus Mobile Low mesh construction in 2,858.724 ms, a 797.753 ms maximum individual track, and 120 warm lookups in 18.657 ms. Generation occurs before active racing; it is not represented as a race-time frame cost.

Evidence: [`../evidence/logs/full-check-20260725T192237Z.log`](../evidence/logs/full-check-20260725T192237Z.log), SHA-256 `fac5a01f2c6db14d9a8c780e9fb735ccf52bb5325ac993615eb1a339f8dcba82`.

## Automated development-host telemetry

`tests/race/run_ai_soak.sh` records per-track hashes, field size, lap count, fixed ticks, simulated duration, host wall time, finishes/DNFs, invalid/non-finite state, stagnant windows, contacts, automatic recoveries, same-seed authority digests, primary fixed ticks, twin authority vehicle-steps, and normalized throughput. Lengthening the built-ins by 2.5× made the old absolute `900,000 ms` gate obsolete even though AI correctness remained green. The current schema-2 gate keeps all four 12-car × 20-lap representative runs and all 20 corpus runs, raises only the absolute development-host allowance to `2,700,000 ms`, and adds a hardware-normalized minimum of `1,100 authority vehicle-steps/s`. These are host-regression gates, not rendered frame-time or mobile thermal results.

`backend/scripts/run_local_12_client_load.sh` records bounded authentication/admission, input relay, snapshot delivery, elapsed time, runtime diagnostics, and secret/token scans against a disposable loopback stack. It is functional local load evidence, not distributed-network capacity, mobile radio behavior, or the required RTT/jitter/loss profile.

### Current longer-track release-component result

The one-shot [`../evidence/logs/full-check-20260724T142719Z.log`](../evidence/logs/full-check-20260724T142719Z.log), SHA-256 `3727c0960a494ef71745cb8a72dbefe496fcb54e85ae63e6d67cd4d409194682`, passed every pre-soak check and all AI correctness requirements. It stopped solely because 2,075,104 ms exceeded the obsolete 900,000 ms absolute wall gate; it did not continue to the backend stages and is **not** represented as a one-shot release PASS.

The unchanged-coverage soak was rebaselined as described above and rerun. The current schema-2 [`../evidence/runtime/ai_soak_report.json`](../evidence/runtime/ai_soak_report.json), SHA-256 `aeb497dd8dc6b3c5e439eb03b14b6437e6f75f527923e90c8b45afa63abc2247`, is PASS:

- 2,084,371 ms wall time, below the 2,700,000 ms host ceiling.
- 122,246 primary fixed ticks and 2,933,904 twin authority vehicle-steps.
- 1,407.6 authority vehicle-steps/s, above the 1,100 minimum, or 710.4 microseconds per authority vehicle-step.
- 4/4 representative runs and 20/20 corpus tracks passed; all 288 car entries finished deterministically with zero DNF, invalid, non-finite, stuck, or recovery outcomes.

The current real-Nakama E2E rerun also passed 102 assertions. The current 12-client load passed 1,011 assertions; evidence: [`../evidence/logs/nakama-12-client-load-20260724T154614Z.log`](../evidence/logs/nakama-12-client-load-20260724T154614Z.log), SHA-256 `e91055a45f4f2aa442db43ce659cfeff7978d099831f53a491d2640023bc386a`. The isolated PostgreSQL backup/restore rerun passed 12 checks; evidence: [`../evidence/logs/postgres-backup-restore-20260724T154648Z.log`](../evidence/logs/postgres-backup-restore-20260724T154648Z.log), SHA-256 `782bfd3907de2983f75766e7f856aba977f573f13f11862f867c5616695a7bde`.

Accordingly, every release component is green in combined current evidence. A future immutable candidate should still produce a fresh one-shot `--release` PASS log rather than treating this combined record as one.

### Historical pre-upgrade development-host result

Gate `20260723T214917Z` recorded a deterministic AI soak of 707,127 ms, below the then-frozen 900,000 ms ceiling: all 12 cars completed 20 laps on each of four representative tracks, 20/20 generated-corpus tracks passed, and no DNF/invalid/non-finite/stuck outcome occurred. Report SHA-256: `0d81eb28cefd860be618288f5463894dcef2308b53a151f5ff78fce9c81bdd88`. This predates the 2.5× built-in-track revision and is historical regression evidence only; the schema-2 result above supersedes it for the current tracks.

The disposable real-Nakama load passed 1,011 assertions in 4,633 ms with 12 admissions, one expected overflow refusal, 55 relayed inputs, 33 snapshot deliveries, and zero Godot/backend/warning/leak/secret/token diagnostic counts. Evidence SHA-256: `fbc15f905fb3d8fd797ee542fe7b1a6a2a1493a3da3ee8309bdba1b8d47d60ac`.

Both figures are development-machine functional regression evidence. They do not satisfy any 60/30 FPS, render frame-time, memory, radio, battery, or thermal criterion below.

## Measurement protocol

For every capture record build/commit, export preset, device model/OS, power mode, battery/temperature start, scene/track hash, car/player count, duration, graphics mode, and profiler versions.

Report frame-time median/p95/p99/max and missed-frame count—not average FPS alone. Also record main/render/physics time, draw calls/items, node count, memory peak/growth, allocations/GC symptoms, battery/thermal state, load stalls, AI update cost, and network RTT/jitter/loss/correction distance/bandwidth.

Run cold start, three-minute focused capture, 20-lap soak, and 30-minute thermal test. Repeat after the device stabilizes; compare like-for-like builds and keep raw captures under the evidence policy.

## Pass criteria

- Primary tier: p95 frame time within 16.67 ms in mandatory scenarios with no recurring severe spike.
- Fallback tier: p95 within 33.33 ms with stable pacing.
- No upward unbounded memory trend, recurring collection stall, race-time asset hitch, thermal crash, or OS memory termination.
- Network correction remains visually bounded under the accepted impairment profile; disconnects have classified reasons.
- Visual reductions preserve gameplay readability and authority.

Numeric memory, bandwidth, correction, temperature, and spike thresholds remain **TBD** until device/network baselines exist. Do not invent pass values after observing a preferred result; freeze them before final validation.

## Regression policy

A performance-sensitive change includes before/after captures on the same scene/device. A statistically meaningful regression blocks release or receives a documented budget trade-off. Screenshots alone are not performance evidence.
