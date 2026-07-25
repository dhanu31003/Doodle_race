# Offline AI

Status: **implemented behavior; current longer-track deterministic release soak passed**. AI drivers, personalities, traffic tactics, bridge-aware navigation, collision handling, and deterministic authority recovery exist. The schema-2 full-coverage soak passes both its absolute development-host ceiling and normalized authority-throughput floor. Exact evidence and mobile limitations are summarized below and in `TEST_REPORT.md`.

## Goals

- Support configurable 2–12-driver offline grids: one player plus 1–11 AI opponents. The dedicated release soak may run all 12 slots as AI-controlled test cars.
- Race credibly: follow lines, brake, overtake, defend, avoid, recover, and make varied but bounded decisions.
- Difficulty changes consistency, perception, braking confidence, patience, and risk—not hidden grip or impossible top speed.
- Consume the same vehicle input command interface as a human driver.

## Inputs generated with the track

- Center, ideal, left, and right lanes sampled by arc length.
- Curvature-derived base speed profile and brake zones.
- Overtake, no-overtake, pit/merge, bridge, checkpoint, and recovery zones.
- Track width/edge clearance, surface, bridge layer, and safe reset transforms.

Navigation data is derived deterministically from the pinned `TrackDefinition` and generator. AI must not infer authority from rendered pixels.

## Control stack

1. **Perception:** own progress/state; nearby cars in a bounded forward/rear window; lane clearance; next corners/brake zone; track/bridge layer.
2. **Tactics:** follow, attack, pass-left/right, defend, yield, avoid, recover, and finished states.
3. **Planner:** selects a target lane, look-ahead point, and speed curve with hysteresis to prevent lane oscillation.
4. **Controller:** bounded steering plus throttle/brake commands at a fixed decision rate, held/interpolated by the fixed-step vehicle simulation.
5. **Safety/recovery:** collision/time-to-contact override, off-track return, spin correction, and reset after a measured stuck threshold.

AI emits conventional steering, accelerator, and brake/reverse only. The legacy `RaceInput.nitro` compatibility bit is forced false; no AI receives a hidden boost advantage.

All expensive neighbour queries use spatial partitioning or bounded lists. Per-car `_process` work and unbounded raycasts are prohibited without profiling evidence.

The 12-car start grid now uses a nine-authority-unit stagger pitch. Same-lane cars begin 18 units apart, beyond the 16-unit collision capsule, so the first collision pass performs 66 checks with zero penetration/resolution instead of spending the opening frames separating overlapped cars.

## Current built-in circuit revision

All six built-in circuits are exactly 2.5× their previous authority length and 12 units wider. Their physical laps now range from 1,199.976 m to 1,379.969 m, and widths range from 13.2 m to 14.4 m. AI consumes the regenerated deterministic lane, curvature, braking, checkpoint, and recovery data rather than assuming the old lap duration. Custom tracks and their hashes are unchanged.

The catalog/mesh benchmark in the current normal gate passed with at most 767 samples, 460 mobile mesh segments, and 5,520 triangles per built-in. Generation remains outside active race time. Formula/AI/race authority targeted suites and the full 20-lap release soak on the longer built-ins pass.

## Personalities

Each AI has a deterministic race seed and bounded values for aggression, patience, consistency, reaction delay, braking confidence, risk, and defensive tendency. Team/livery does not imply real people or protected identities. Personality variance must remain within the same legal vehicle envelope as the player.

Difficulty presets map to distributions rather than exact scripts. A rerun with the same race seed should be reproducible enough for diagnosis; any intended noise uses a named seeded stream.

## Racing behavior

- Pass only with a viable gap, sufficient straight/corner allowance, and no no-overtake/bridge transition conflict.
- Maintain lateral margin side-by-side and concede when predicted overlap becomes unsafe.
- Defend with one deliberate line decision; do not weave reactively.
- Brake for curvature and traffic; use the same acceleration, braking, reverse, and steering limits as the player.
- Use alternate lines so the field does not settle permanently into one train.
- Preserve ordered checkpoint progress and current bridge layer during every maneuver.

## Recovery

Detect lack of progress using classification progress/checkpoint change, speed, recent wall contact, and off-track state—not speed alone. The driver first steers/reverses toward the route. Race authority may then perform a hard recovery after five seconds without progress while slow and off-track or recently blocked, followed by an eight-second cooldown. Recovery uses a valid route projection, retains lap/checkpoint authority, resets only motion/projection state, increments a parity serial for network hard-snap reconciliation, and records a bounded diagnostic event.

## Current longer-track release soak

The current schema-2 [`../evidence/runtime/ai_soak_report.json`](../evidence/runtime/ai_soak_report.json), SHA-256 `aeb497dd8dc6b3c5e439eb03b14b6437e6f75f527923e90c8b45afa63abc2247`, passed:

- Four of four representative runs completed with 12/12 cars over 20/20 laps, and the frozen generated corpus passed 20/20 tracks.
- All 288 car entries finished deterministically with zero DNF, invalid, non-finite, stuck, or recovery outcomes.
- The runner executed 122,246 primary fixed ticks and 2,933,904 twin authority vehicle-steps.
- Wall time was 2,084,371 ms, below the rebaselined 2,700,000 ms development-host ceiling.
- Normalized throughput was 1,407.6 authority vehicle-steps/s, above the 1,100 minimum, or 710.4 microseconds per authority vehicle-step.

The 2.5× built-in length increase made the earlier absolute 900,000 ms ceiling obsolete. A one-shot release attempt completed every representative/corpus correctness check in 2,075,104 ms but stopped on that old wall gate; evidence: [`../evidence/logs/full-check-20260724T142719Z.log`](../evidence/logs/full-check-20260724T142719Z.log), SHA-256 `3727c0960a494ef71745cb8a72dbefe496fcb54e85ae63e6d67cd4d409194682`. Rebaselining did not remove a track, car, lap, same-seed twin, or corpus case. The added normalized minimum prevents the larger absolute allowance from masking a throughput regression.

This closes the deterministic functional/development-host AI gate for the current longer circuits. It does not qualify target-device CPU, rendered frame-time, memory, battery, or thermal behavior.

## Historical pre-upgrade soak result

Gate `20260723T214917Z` passed all representative and generated-corpus requirements:

- Evergreen Oval, Copper Canyon, generated S-bends, and generated Bridge Eight: 12/12 cars completed 20/20 laps deterministically on every track, with zero DNF, invalid, non-finite, or stuck outcomes.
- Representative recoveries were 0, 1, 1, and 10 respectively; Bridge Eight stayed within the four-per-car limit.
- Frozen generated corpus: 20/20 tracks passed (100%), 12/12 cars completed each, five recoveries total, at most one per car, and zero DNF/invalid/non-finite/stuck outcomes.
- Aggregate development-host wall time was 707,127 ms under the frozen 900,000 ms ceiling.
- Historical report snapshot SHA-256: `0d81eb28cefd860be618288f5463894dcef2308b53a151f5ff78fce9c81bdd88`. The live report path now contains the current schema-2 result above.

This closed the deterministic functional/host-regression AI gate for the previous shorter built-in circuits. It does not qualify the current 2.5× built-ins; the schema-2 result above does. Target-device CPU, rendered frame-time, memory, battery, and thermal qualification remains open.

## Acceptance gates

- Every car completes 20 laps on oval, S-track, technical, and bridge golden fixtures.
- At least 95% of a frozen valid generated-track corpus completes without stuck cars.
- No car remains stopped beyond the defined recovery threshold.
- Automatic recovery remains bounded to at most four per car on representative golden tracks and two per car on the generated corpus.
- Overtake and collision-recovery fixtures pass; no permanent single-file train in representative soaks.
- Checkpoints, resets, bridge layers, and finish order remain valid.
- Difficulty distributions show meaningful outcome/consistency differences without higher physical limits.
- Twelve-car first-corner and 20-lap soaks stay within CPU/frame/memory budgets on the target device matrix. The soak runner's current 2,700,000 ms development-host wall-clock ceiling and 1,100 authority vehicle-steps/s minimum are regression evidence only, not mobile FPS, memory, or thermal budgets.

Results require seeds, track hashes, build version, device, duration, percentiles, failures, and evidence paths. One successful replay is not a pass.

## Diagnostics

For failed soaks record per AI: state transitions, input commands, spline progress, layer, target lane/speed, nearest threats, recovery attempts, collisions, checkpoints, seed, and stable failure code. Production logging is rate-limited and redacts player/network identifiers.
