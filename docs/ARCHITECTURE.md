# Architecture

Status: **implemented candidate architecture**. The boundaries below describe the current repository. Verification outcomes and remaining release gates are tracked in `TEST_REPORT.md` and `PROJECT_STATUS.md`; implementation presence alone is not a PASS.

## Baseline

- Godot 4.7.1 stable and GDScript, with deterministic 2D race authority mapped into a dedicated world-space 3D race renderer.
- Landscape Android/iOS client; desktop/editor builds are development surfaces.
- Deterministic data-first track generation and race rules separated from scenes.
- Offline-first client with a replaceable Nakama multiplayer adapter.
- Custom headless GDScript runner, integration scenes, deterministic visual scenes, and export smoke checks.

The decisions are recorded in `adr/0001-engine-and-language.md` and `adr/0002-multiplayer-architecture.md`.

## Dependency rule

```text
UI / scenes / platform adapters
             ↓
application controllers (studio, race, room, save)
             ↓
pure domain (track math, race rules, AI decisions, protocol codecs)
             ↓
versioned data contracts
```

Dependencies point inward. Domain code must not read the scene tree, renderer, clock, filesystem, network socket, or platform APIs directly. Inject time, random seeds, storage, and transport. Rendering consumes immutable/generated data; it never becomes authoritative state.

## Repository boundaries

| Area | Responsibility | Must remain independent of |
|---|---|---|
| `game/app`, `game/core`, `game/config`, `game/settings` | startup/services, shared value types, feature/config gates, settings application | feature scenes |
| `game/track/definition` | schema, canonical codec, hashing, migration | renderer and physics |
| `game/track/authoring` | stroke history and user-visible fixes | race session |
| `game/track/generation` | curve, arc-length samples, lanes, grid, pits, bridges | UI nodes |
| `game/track/validation` | bounded deterministic validation and diagnostics | presentation text |
| `game/track/features` | seeded scenery plus pits, grid, bridge, minimap, lanes, and tour plans | save/network authority |
| `game/vehicle` | arcade vehicle simulation and input command | UI widgets |
| `game/ai` | perception, decisions, personalities, recovery | sprite/animation state |
| `game/race` | countdown, checkpoints, laps, order, finish | backend transport |
| `game/presentation3d` | coordinate mapping, generated track mesh, Formula-car visuals, fixed scenery, daylight, and cockpit/chase cameras | authority mutation and race decisions |
| `game/network`, `backend` | protocol/client adapter plus Nakama RPC/match lifecycle | generated pixels and decoration |
| `game/persistence` | atomic repository, backup, migrations, portable export/deletion | concrete UI |
| `game/ui`, `game/ui/input` | safe areas, haptics, lifecycle-facing controls, camera presentation | domain rules |
| `game/ui`, `game/audio` | presentation and audio routing | authority decisions |

## Track pipeline

`RawStroke` → cleanup → closure proposal → smoothing → arc-length resampling → physical scale → metrics → validation/auto-fix proposal → start/pit/bridge resolution → immutable `GeneratedTrack` → collision/render/navigation/decoration projections.

- The saved/networked authority is `TrackDefinition`, never generated road pixels or decoration instances.
- Each generation run is keyed by schema version, generator version, canonical definition hash, and seed.
- A failed stage returns a stable diagnostic code plus safe player-facing explanation.
- Expensive generation may move to a worker, but Godot objects/scenes are created only on the main thread from validated plain data.

## Race simulation

- Fixed-step simulation; display interpolation must not alter authority.
- Formula-style vehicle authority uses an eight-speed sequential automatic gearbox, road-speed/RPM coupling, shift torque cuts, engine braking, speed-sensitive bicycle steering, tyre slip/grip, aerodynamic load, versioned road-surface profiles, and bounded carbon-brake/traction behavior. Crest launches follow a fixed-step standard-gravity arc with no tyre force while airborne. Exact parameters and tested limits are in `VEHICLE_DYNAMICS.md`.
- Shipped player input is an explicit bounded command: steering, throttle, brake/reverse, sequence, and tick. A dormant nitro bit remains only in the versioned internal/replay contract for compatibility and is forced false at race and network authority boundaries.
- Vehicle state is plain serializable data suitable for tests and snapshots, including gear/RPM/shift, physical rack position, slip, and lateral-load telemetry.
- Ordered checkpoint passage plus lap count and spline progress determine ranking.
- Bridge layer is part of vehicle/progress state and collision filtering.
- AI produces the same input command type as human controls.

Offline uses the local simulation directly. Multiplayer v1 uses a casual client host as simulation authority; guests predict their local car and interpolate remote snapshots. The host validates inputs and race rules. Backend unavailability never disables offline services.

The inventoried `icon_boost.svg` and `boost.wav` resources are dormant legacy/internal compatibility assets. No shipped control, AI command, or network message can activate boost, and no player-facing screen exposes either resource. Their eventual package inclusion/exclusion remains an asset-ledger decision, not a gameplay feature.

## Presentation

World rendering, HUD, camera, particles, and audio subscribe to domain events. Cosmetic events may be dropped or pooled. Persistent decisions—checkpoint, lap, finish, and reset—come only from authority. `WorldCoordinateMapper` converts authority X/Y into world X/Z and normalized bridge elevation into metres; generated track and scenery roots remain at identity while vehicle Node3Ds move through them. Grounded presentation derives car pitch from bounded forward/back road probes and preserves ride clearance; airborne pitch derives from the ballistic velocity, never the road. The player car keeps its complete halo in cockpit but hides the four forward triangular bars in chase, while remote cars retain their full silhouette. Surface weather/debris is presentation-only and uses one rain field, one static `MultiMesh`, a fixed four-emitter pool, and one instanced coating draw per affected car rather than per-particle/per-speck nodes. Cockpit and chase cameras follow the interpolated player transform and consume the same immutable race state; neither is authoritative. Chase translation/yaw stay attached to the player while only road-grade pitch is exponentially eased and rate-limited, preventing abrupt bridge nods without positional lag. UI navigation must work with touch and controller and honor safe-area/accessibility settings.

## Persistence

- Versioned save envelope and per-entity schema versions.
- Write temporary file, flush/close, rotate backup, atomic replace where supported.
- Validate before replacing the last known-good file.
- Migration operates on a backup and is idempotent.
- Corrupt or future-version data is quarantined, not silently overwritten.

## Backend boundary

The implemented local stack is Nakama `3.40.0` (`sha256:92fb184e3271be12fd4d239766afb285322a50aaf769a59433445d59624c78cd`) plus PostgreSQL `17.9-alpine3.23` (`sha256:c7526c0f6c3f30260a563d7bcf8ad778effac59a44f8ffa86678c35418338609`) in Docker Compose. The vendored Nakama Godot SDK is `3.4.0` at commit `14b7f7078a9822c15b0424624e4c883c87730cee`. Nakama handles anonymous sessions, short-code RPCs, room/match presence, transient track-manifest relay, and race messages; it does not persist or own generated geometry. Production secrets, TLS, DNS, encrypted backups, monitoring, retention, and hosting remain deployment concerns requiring explicit approval.

## Determinism and compatibility

- Quantize all authoring geometry before canonical encoding.
- Use stable integer identifiers and explicit units; reject NaN/infinity before arithmetic.
- Do not rely on dictionary iteration order, frame delta, locale, or global RNG.
- Keep golden fixtures for every released track schema/generator pair.
- Network handshake pins app build, protocol, schema, and generator; incompatible peers cannot ready.

## Error model and observability

Domain errors use stable codes with stage and safe context. Logs are structured and redact tokens, room secrets, install identifiers, and raw user-entered text. Every generation/network failure shown to a player includes a non-secret diagnostic ID that can correlate with local/backend logs.

## Security boundaries

- Strict size, type, enum, finite-number, rate, and range validation at every trust boundary.
- Host authority is not cheat-proof; this limitation is explicit and acceptable only for private casual rooms.
- No deserialization into executable Godot objects from network payloads.
- Nakama session/reconnect material currently remains in runtime memory and is cleared on leave/reset/local deletion. Platform secure-store persistence is not implemented. Secrets never enter repository config.

## Current implementation status

The repository contains the end-to-end offline flow, strict track pipeline, persistence/settings services, race/AI authority, true 3D race presentation, Nakama client/backend adapters, and mobile export presets described above. Local headless runners, deterministic capture scenes, backend drills, and export tooling are also implemented. Consult `PROJECT_STATUS.md` for the current candidate state and `TEST_REPORT.md` for evidence; these source boundaries do not establish public-service, signed-store, physical-device, thermal, or cross-platform determinism results.
