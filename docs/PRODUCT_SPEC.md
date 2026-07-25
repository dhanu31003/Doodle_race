# Product Specification

Status: **design baseline**, 2026-07-23. This document states the intended product; it does not assert that a feature is implemented or tested.

## Product promise

RaceGlyph (provisional name; no legal clearance) turns a single hand-drawn loop into an original, polished circuit that can be toured, raced offline, saved, and shared with friends in a private room. Driving is presented from switchable cockpit and elevated chase views, never an overhead gameplay camera.

## Audience and session

- Players who want approachable mobile racing and creative track making.
- Landscape phones and tablets on Android and iOS.
- Typical loop: draw or choose track → validate/generate → tour → configure race → race → results → retry/edit/share.
- Offline is the default dependable mode; a backend outage must not block local play.

## Non-negotiable experience

1. A one-finger or mouse stroke remains visibly recognizable after smoothing and auto-fix.
2. Validation explains failures and previews every automatic correction before acceptance.
3. The generated road is crisp, continuous, navigable, and deterministic at supported zoom levels.
4. Touch driving feels responsive; assists change accessibility, not maximum unfair speed.
5. Driving uses familiar controls only: left/right steering, accelerator, and brake/deceleration; holding brake at rest engages reverse.
6. AI produces contested races, can overtake and recover, and respects checkpoints and bridge layers.
7. Private rooms fail clearly and recover where safe; version/hash mismatches never start a race.
8. All identity, art, audio, and text are original or release-compatible and documented.

## Modes

### Track Studio

- Draw one closed line with touch or mouse.
- Undo, redo, clear, confirm, closure guidance, live smoothing, and haptic validation feedback.
- Keep drawing controls under `DRAW TRACK`; place length, width, direction, pit side, theme, road surface, and decoration density in a separate clipped `WORLD & ROAD` section.
- Validate closure, bounds, radius, start straight, grid, pit feasibility, and crossings. Apply only very-local rounding to unsafe extreme points, create safe bridges at clean crossings, and choose the safest viable grid automatically.
- BUILD CIRCUIT proceeds directly to the circuit tour. There is no manual grid-position review or MOVE GRID confirmation page.
- Save, reload, rename, edit, thumbnail, export, and delete local tracks.

### Offline Race

- Predefined or user-created track.
- Configurable 2–12-driver grid: one player plus 1–11 AI opponents, with lap count, difficulty, assists, and collision configuration.
- Intro, countdown, ordered checkpoints, lap/sector/best times, live position, minimap, pause, finish order, restart, and return to studio. After the player takes the flag, remaining AI continue under authority and the results panel updates each exact finish time until the complete field is classified.
- Toggle at any time between an in-cockpit view with a responsive steering wheel and an elevated behind-the-car chase view.
- Fully functional without authentication or network access.

### Private Multiplayer

- Anonymous identity and short alphanumeric room code.
- Up to 12 human slots. Optional AI fill is explicitly deferred from v1; empty slots remain invite slots.
- Host selects a predefined/saved circuit or opens Track Studio and returns to the same room with the canonical result. Cancel returns without publishing a track.
- Host configures laps/collisions, kicks, and explicitly locks or unlocks the grid before countdown. Locking closes invites and freezes circuit/rule/kick changes, while verified members may still acknowledge Ready; start requires a locked, fully ready grid.
- Every member selects an original fictional team/car. The authoritative roster carries those selections into the lobby and race presentation.
- Admission requires an exact app-build/protocol/schema/generator/platform tuple. Track readiness separately requires the same canonical definition hash and successful local generation; incompatibility opens a blocking update-required surface while offline play remains available.
- The race HUD includes sector timing; guest-local sector prediction is labeled `LOCAL` and is never presented as host authority.
- Authoritative results can be copied without room codes or internal peer identifiers. Guests may request a rematch; only the host can reset the same verified room, preserving the grid lock while clearing Ready acknowledgements.
- Casual host-authority model; no ranked mode or strong anti-cheat in v1.

## Screens

Splash/loading, main menu, Offline Race, Multiplayer, Track Studio, Saved Tracks, Predefined Tracks, Garage, Settings, Accessibility, Credits/Licenses, create/join room, lobby, host drawing, generation readiness, race HUD, pause, results, and explicit error/reconnect/update-required dialogs.

All screens require safe-area support, phone/tablet responsiveness, readable type, large touch targets, consistent focus/controller navigation, and motion that honors reduced-shake settings.

## Track output

The deterministic pipeline produces road, edge, curbs, markings, runoff, barriers, fencing, pit lane/building, start/finish, grid, ordered checkpoints, racing lanes, minimap, bridge layers, recovery points, seeded decoration, and one of five released surfaces: smooth asphalt, weathered asphalt, bumpy asphalt, compact gravel, or mud. Each surface has distinct geometry-scale texture language, roughness, drive efficiency, speed drag, rolling resistance, tyre grip, braking, AI target speed, grounded suspension motion, vehicle coating, and bounded moving presentation effects. Weathered asphalt has wet film/rain/mist; bumpy asphalt has irregular repairs/cracks/chips and road dust; gravel has aggregate/stones/tan dust; mud has ruts/puddles/clods/dark spray and body splatter.

## Driving and presentation

- Arcade acceleration, braking, reverse, speed-sensitive steering, grip/slip, drag, deterministic surface effects, collisions, bounded gravity-driven crest airtime, exact landing, and reset/recovery.
- Touch buttons or steering wheel, accelerator, brake/reverse, optional tilt, left-handed layout, optional auto-accelerate, steering/braking assists, keyboard, and controller. Auto-accelerate is off by default.
- Cockpit camera with visible steering-wheel response and complete halo guard plus elevated chase camera with restrained look-ahead/shake, separately smoothed bridge-grade pitch, and the forward triangular halo frame hidden; dynamic shadows, grade-aligned body response, smoke, rain, spray, dust, sparks, debris, skid marks, and brake glow.
- Plan-view imagery is limited to Track Studio, circuit selection/tour, and the HUD minimap. The race viewport is always perspective.
- Independent master, engine, effects, ambience, UI, and music levels.

## Accessibility

- Scalable high-contrast UI and color-blind-safe state indicators.
- Large movable controls, sensitivity/dead-zone settings, left-handed layout.
- Auto-accelerate, steering assist, braking assist, haptics toggle, and screen-shake slider.
- Battery/performance modes and correct interruption/background handling.

## Save and data

Local saves include tracks and thumbnails, settings, selected fictional team/car, best laps, and results. Writes must be atomic, backed up before migration, recoverable after corruption, versioned, and exportable/deletable. Personal data is not collected unless a documented feature strictly requires it. See `PRIVACY_DATA_MAP.md`.

## Success gates

- A complete draw/save/edit/delete/tour/race loop on both target platforms.
- Cockpit and chase races both complete cleanly with identical authoritative physics and conventional controls.
- Generated track features and valid bridges satisfy deterministic unit/integration fixtures.
- AI completes 20-lap golden-track soaks; at least 95% of valid generated-track fixtures complete without stuck cars.
- Twelve-car first corner, dense decoration, and bridge cases meet measured budgets.
- Private predefined and host-drawn room flows pass ready/hash/version, latency/loss, reconnect, and authority tests.
- Android and iOS artifacts are produced as far as credentials allow.
- Automated, visual, device, and 30-minute thermal evidence is recorded; no critical/high defects remain.

These are release gates, not current results.

## Explicit exclusions for v1

- Ranked competition, prizes, economy, advertising, chat, public matchmaking, and strong anti-cheat.
- Real teams, drivers, sponsors, circuits, trophies, or Formula 1 branding.
- Wear/pit strategy unless a later decision proves it complete and fun without delaying core quality.
- Public deployment, store submission, paid hosting, or paid assets without owner approval.
- Private-room AI fill. V1 ships human-only private grids; this must not be presented as implemented.

## Open product decisions

- Final legally cleared title, package ID, bundle ID, age rating, and store territories.
- Minimum supported OS versions, selected from measured device/export evidence.
- Final content count beyond “several” predefined tracks and fictional team colorways.
- Whether private-room AI fill should return in a later release after authority and soak validation.
