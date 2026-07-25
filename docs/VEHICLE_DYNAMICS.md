# Formula Vehicle Dynamics

Status: **implemented deterministic Formula-style model**. This model targets credible visual/audio behavior and controllable mobile racing; it is not a homologated engineering simulator or a claim of one-to-one telemetry parity with a specific real car.

## Authority contract

- Simulation runs at a fixed 60 Hz. Human, AI, replay, host authority, and guest prediction execute the same `ArcadeVehicleModel` and bounded `VehicleConfig`.
- The only player commands remain steering, accelerator, and brake/reverse. Automatic shifting does not add a new network input.
- Position, velocity, heading, physical rack position, gear, engine RPM, shift ticks, slip angle, driven-wheel slip, and lateral acceleration are quantized before an authority snapshot.
- Protocol 2 / app build 0.2.0 is the live compatibility boundary. Protocol-1 peers are rejected before room admission because their predictor used the previous vehicle model.

## Eight-speed drivetrain

| Parameter | Value |
|---|---:|
| Forward gears | 8 |
| Gear speed ceilings (world units/s) | 72, 108, 146, 184, 221, 255, 285, 310 |
| Downshift thresholds (world units/s) | 0, 55, 88, 121, 154, 187, 219, 250 |
| Idle / launch / upshift / redline | 4,500 / 6,500 / 11,800 / 12,500 RPM |
| Shift torque-cut duration | 5 fixed ticks, 83.3 ms |
| Torque available during shift | 8% |
| Per-gear acceleration factors | 1.00, 0.96, 0.89, 0.82, 0.75, 0.69, 0.63, 0.58 |
| Reverse acceleration / limit | 30 / 58 world units/s |

RPM is coupled to road speed and the selected ratio. Every upshift is sequential, drops RPM, and applies the same deterministic torque cut to player and AI. Closed throttle adds ratio-aware engine braking. Brake selects reverse only after forward speed reaches the neutral threshold; accelerator while reversing selects first and applies positive tractive force through neutral, so neither pedal can strand the car in a dead gear.

## Longitudinal forces

- Base engine acceleration is `58`, shaped by RPM and gear.
- Launch traction capacity is `43 + 0.00020 × speed²`; excess requested force becomes bounded wheel-slip telemetry instead of free acceleration.
- Carbon-brake capacity is `76 + 0.0010 × speed²`, representing aerodynamic load while a bounded move-to-zero layer prevents numerical lockup or reverse overshoot.
- Coasting resistance is `3.8`; maximum engine-brake contribution is `10.5`.
- Quadratic aerodynamic drag is `0.00024 × speed²` and always opposes travel.
- The display calibration is 1 world-speed unit = 1.08 km/h. Automated launch and braking contracts require 0–100 km/h in 2.0–2.7 seconds and 200–0 km/h in 1.6–2.6 seconds.

## Steering, tyres, and aerodynamic load

- Steering rack input moves at 5.4 normalized units/s and self-centres at 7.2 units/s; it never snaps directly to a touch/controller request.
- Maximum front-wheel angle fades smoothly from 0.47 rad (26.9°) at low speed to 0.153 rad (8.8°) by 235 world units/s.
- A bicycle yaw model uses an 18-world-unit effective wheelbase. The chassis rotates independently of world velocity, creating measurable slip rather than rotating velocity for free.
- Lateral tyre capacity is `65 + 0.00168 × speed²` world units/s². With the shared 0.30 m/world-unit scale this peaks at 6.93 g at the 310-unit speed limit; the tyre-limited minimum radius there is approximately 127 m.
- Lateral response is 8.8/s normally and 4.2/s in a deliberate high-speed slide. Peak slip angle is 0.19 rad (10.9°); grip falls progressively but never below 56% before off-track modifiers.
- Grass reduces engine authority, traction, and lateral capacity and adds a deterministic 125-unit/s slowdown. Barrier/contact response remains mass-aware and bounded.

The AI now scans farther into the braking horizon and chooses curvature speeds from this same tyre envelope. Difficulty changes decision quality and risk only; it does not receive extra grip, braking, power, gears, or top speed.

## Presentation and networking

- Cockpit and chase presentation consume the physical rack position, not raw input. Cockpit shift lights and gear display consume authoritative RPM/gear/shift ticks.
- Offline and network HUDs share one gear/RPM formatter. Engine audio pitch follows RPM, produces a bounded audible shift dip, and uses a restrained reverse tone.
- Protocol-2 snapshots carry an all-or-nothing fixed-point Formula telemetry set. The backend validates the same bounds, Nakama normalizes the fields, local prediction replays them, and remote interpolation blends continuous telemetry while stepping discrete gear state.
- Archived v1-shaped snapshots remain decode-safe with explicit first-gear, 4,500-RPM, centred-rack, and zero-slip defaults. They are not accepted as live protocol-2 peers.

## Focused verification

- Race authority: 359 assertions passed, including eight sequential gears, seven RPM drops, torque cut, engine braking, 0–100 and 200–0 windows, neutral/reverse/forward transitions, steering-rate and radius behavior, lateral-g ceiling, tyre slip recovery, deterministic replay, 12-car AI, bridge traversal, and both off-track/contact recovery paths.
- Network protocol/fake/runtime: 468 assertions passed, including bounds, optional legacy decoding, drivetrain/steering/slip round-trip, prediction, interpolation, and clean process shutdown.
- Audio, shared HUD/persistence, and race-screen integration have dedicated focused suites. Their latest results are recorded in the task handoff and should be rerun with the final candidate gate.

## Deliberate limits

Tyre temperature, tyre wear, energy recovery deployment, fuel mass, suspension geometry, differential maps, wet-weather compounds, damage, manual clutch, and manual gear selection are outside this accessible v1 gameplay scope. Adding any authority-affecting subsystem requires a new deterministic test panel and another compatibility-version decision.
