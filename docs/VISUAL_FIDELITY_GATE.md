# Visual fidelity gate

The uploaded 60-second reference video is the acceptance target for the race presentation. A green unit suite alone does not satisfy this gate; the current build must also be reviewed from a moving chase camera and a moving cockpit camera.

## Required evidence

| Requirement | Authoritative evidence | Pass condition |
| --- | --- | --- |
| True world-space motion | `--autodrive` fixture log plus moving capture | Player and camera travel through the circuit while track and scenery roots remain at identity. |
| Formula silhouette | Front three-quarter, rear chase, and cockpit renders | Smooth modern open-wheel proportions, separated aero surfaces, four convincing slicks, suspension, halo, mirrors, driver and differentiated materials; no primitive-block placeholder read. |
| Cockpit | Moving cockpit capture during a turn and gear change | Camera is rigid to the survival cell; visible halo, front tyres, nose, hands, detailed yoke, live gear/RPM and shift LEDs do not swim under the camera. |
| Circuit surface | Moving chase and cockpit capture | Asphalt has scale-correct PBR detail and a rubbered racing line; kerbs, white lines and runoff remain grounded without z-fighting or back-face loss. |
| Trackside world | One complete-lap capture | Coherent trees, fences, barriers, pits, patterned billboards, populated grandstands, grounded audience terraces, lights and braking/sector cues provide depth while clearing the full runoff envelope. |
| Daylight rendering | Histogram/visual review on the target Mac | Blue daylight sky, directional shadows, grounded contact shading, controlled highlights and atmospheric distance; no night palette or flat white geometry. |
| Vehicle dynamics | Telemetry log and moving capture | Real gear progression, visible steering/wheel rotation, bounded pitch/roll/heave and camera response agree with authoritative state. |
| Field behavior | Moving 12-car capture | Opponents move independently on the same fixed circuit with stable scale, shadows and no world-scroll illusion. |
| Performance | Real-time target-hardware run | Sustained 60 fps after shader warm-up at 1280x720 on the target Apple M2 quality tier, with a documented lower mobile tier. |
| Release safety | Full QA log | Parser, assets, presentation, race, UI, accessibility and network suites pass without runtime/resource errors. |

## Reproducible motion proof

```sh
godot --headless --path . --quit-after 1100 --fixed-fps 60 \
  --script res://tests/visual/run_race_camera_fixture.gd -- \
  --camera=cockpit --autodrive
```

The fixture prints `DRIVEN_WORLD_PROOF` with player/camera travel and the exact track/scenery origins. This proves the coordinate contract; it does not replace rendered visual review.

## Reproducible target-Mac performance proof

Run this with the normal macOS display driver after the shader cache is warm. Do
not add `--headless`, `--fixed-fps`, or `--write-movie`: those modes do not
measure real display-frame pacing. `--disable-vsync` prevents the host display's
refresh cadence from quantizing the benchmark to a misleading half-refresh FPS;
it does not change the shipped game's VSync setting.

```sh
godot --disable-vsync --path . --quit-after 1250 \
  --script res://tests/visual/run_race_camera_fixture.gd -- \
  --camera=chase --performance-proof
```

The fixture discards the first 180 racing frames, then prints
`RENDER_PERFORMANCE_PROOF` with average reported FPS, average/p95/p99/maximum
wall-frame time, process/physics monitors, peak draw calls, rendered objects,
primitives, and nearby-car coverage. The target-Mac gate is average FPS at least
55, p95 no more than 20.5 ms, p99 no more than 33.3 ms, and no post-warm-up
frame above 50 ms for this 1280x720 twelve-car fixture. A captured movie still
needs separate visual review because this performance pass deliberately does
not encode frames. Performance failures now exit nonzero.

## Latest accepted local evidence

- Moving chase: [`../evidence/screenshots/actual/premium_integrated_chase_fixed_t7_2_20260724.png`](../evidence/screenshots/actual/premium_integrated_chase_fixed_t7_2_20260724.png)
- Moving cockpit: [`../evidence/screenshots/actual/premium_integrated_cockpit_final_t7_2_20260724.png`](../evidence/screenshots/actual/premium_integrated_cockpit_final_t7_2_20260724.png)
- Populated opening venue: [`../evidence/screenshots/trackside_visual_qa_20260724_b/chase00000310.png`](../evidence/screenshots/trackside_visual_qa_20260724_b/chase00000310.png)
- Mobile Low dense chase/cockpit: [`../evidence/logs/mobile_low_dense_chase_trackside_20260724.log`](../evidence/logs/mobile_low_dense_chase_trackside_20260724.log), [`../evidence/logs/mobile_low_dense_cockpit_trackside_20260724.log`](../evidence/logs/mobile_low_dense_cockpit_trackside_20260724.log)
- Standard dense chase/cockpit: [`../evidence/logs/standard_dense_chase_trackside_20260724.log`](../evidence/logs/standard_dense_chase_trackside_20260724.log), [`../evidence/logs/standard_dense_cockpit_trackside_20260724.log`](../evidence/logs/standard_dense_cockpit_trackside_20260724.log)
- Full regression: [`../evidence/logs/full-check-20260724T173534Z.log`](../evidence/logs/full-check-20260724T173534Z.log)

The 2026-07-24 local pass records a fixed world, visible moving car in chase and cockpit, real steering/gears/RPM, a controlled daytime grade, patterned boards, populated stands/terraces, and passing dense-pack timing in both quality tiers on the target Apple M2. Physical Android/iOS qualification remains a separate release gate.

## Completion rule

Do not call the visual upgrade complete while any reviewed frame still contains placeholder car geometry, sparse toy-like scenery, unsafe prop placement, a floating circuit, a sliding cockpit, missing daylight contact shadows, or a stationary capture used as motion evidence.
