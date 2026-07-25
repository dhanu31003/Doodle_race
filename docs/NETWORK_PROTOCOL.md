# Multiplayer Network Protocol

Status: **implemented v2 protocol contract**. This document describes the current wire and room semantics; test outcomes belong in `TEST_REPORT.md`. Nakama relayed host authority is selected in ADR 0002. Local implementation is not evidence of a public, TLS-fronted, or physical-device multiplayer service.

## Model

- Up to 12 friends in a private room. Optional AI fill is deferred from protocol v2; no client or backend may silently create AI occupants.
- Nakama authenticates anonymous installs, resolves short room codes, manages presence/match lifecycle, and relays match data.
- One client is the casual-room simulation host. Guests send bounded inputs; host broadcasts authoritative state and race events.
- Local car prediction and remote interpolation hide ordinary latency; host corrections always win.
- No ranked mode, prizes, or strong anti-cheat in v2. A malicious host can cheat.

## Compatibility handshake

Before match admission, every create/join RPC carries and the backend validates:

```text
app_build, protocol_version, track_schema_version,
generator_version, platform
```

Current protocol version is `2` and the matching application build is `0.2.0`. Protocol 2 is the Formula-dynamics compatibility boundary: protocol-1 peers are rejected before admission so their different gearbox/steering predictors cannot share authority. An exact tuple is required before a room reservation or match presence is created. Unknown/unsupported values return `update_required`; the client presents a blocking update surface with an offline-play escape, and there is no silent downgrade. After admission, canonical definition hash and generation status travel in `TRACK_MANIFEST`/`GENERATION_REPORT` and gate Ready independently.

## Envelope

Every application message contains `protocol`, `opcode`, `room_epoch`, `sender_id`, `seq`, and payload. Tick-bound messages also contain `tick`; bounded request flows may include an optional `request_id`. Binary encoding may replace canonical JSON after golden cross-platform codecs exist; semantics and limits remain versioned.

- `room_epoch` changes whenever a room authority/session is recreated and rejects stale packets.
- `seq` is monotonic per sender/opcode and bounded to JavaScript's maximum safe integer. Protocol 2 does not wrap a live sequence.
- Server-assigned identity is used; a claimed payload identity never overrides transport identity.
- Strings, arrays, rates, numbers, and payload bytes are bounded before allocation/use.

## Opcode registry

| Opcode | Message | Delivery | Sender → receiver |
|---:|---|---|---|
| 1 | `HELLO` / compatibility (reserved; v2 admission uses authenticated RPC) | reliable | peer ↔ authority |
| 2 | `ROOM_CONFIG` | reliable | host → peers |
| 3 | `TRACK_MANIFEST` | reliable | host → peers |
| 4 | `TRACK_CHUNK` | reserved/unimplemented in v2 | — |
| 5 | `GENERATION_REPORT` | reliable | peer → host |
| 6 | `READY_STATE` | reliable | peer ↔ host |
| 7 | `START_AT_TICK` | reliable | host → peers |
| 8 | `INPUT_FRAME` | unreliable/sequenced | guest → host |
| 9 | `STATE_SNAPSHOT` | unreliable/sequenced | host → peers |
| 10 | `RACE_EVENT` | reliable | host → peers |
| 11 | `COSMETIC_EVENT` | unreliable/sequenced | host/peer → peers |
| 12 | `PING_SAMPLE` | unreliable | peer ↔ host |
| 13 | `RESUME_REQUEST` / `RESUME_STATE` | reliable | peer ↔ host |
| 14 | `ROOM_ENDED` | reliable | host/backend → peers |
| 15 | `ERROR` | reliable | authority → peer |

Opcode numbers are reserved by this document and must not be reused with different semantics inside protocol 2.

## Track transfer and ready gate

The host sends only a canonical `TrackDefinition`, never generated road/scenery/pixels. The v2 `TRACK_MANIFEST` carries the complete `track_definition` object, its canonical `source_hash`, `generator_version`, and the host's deterministic `compiled_fingerprint`. Receivers enforce the byte cap before use, validate the full schema and source hash, compile locally, and report the source hash, generator version, and local compiled fingerprint. Start is enabled only when every required participant has a successful matching report and is ready.

The canonical definition cap is `32,768` bytes and the application-envelope cap is `65,536` bytes. A schema-v1 definition therefore travels inline; opcode 4 remains reserved and no released client depends on chunk assembly. Compression or chunking would require a versioned protocol change plus decompressed-size, ordering, and ratio caps.

## Input and snapshots

`INPUT_FRAME` contains the envelope tick/sequence plus `steering`, `throttle`, `brake`, legacy `boost`, and `ack_host_tick`. Steering is an integer in `[-1000,1000]`; throttle and brake are integers in `[0,1000]`. Protocol 2 retains the original `boost` field solely for structural compatibility: it is always serialized `false`, and both client and authority reject `true` as `input_boost_disabled`. No player-accessible boost or nitro control exists. Inputs are normally submitted at 20 Hz, with a hard maximum of 20 frames per sender per second; stale, future, duplicate, malformed, and over-rate frames fail explicitly.

`STATE_SNAPSHOT` contains the authoritative tick and, per active car, `slot`, quantized x/y position, heading, x/y velocity, completed lap, next checkpoint, collision layer/mask, status flags, plus an all-or-nothing Formula telemetry set: `gear`, `engine_rpm_q`, `shift_ticks`, `steering_q`, `slip_angle_q`, `wheel_slip_q`, and `lateral_accel_q`. Flags cover off-track, finished, DNF, and recovery hard-snap parity; boost and an independently trusted progress scalar are not wire fields. The decoder keeps explicit safe defaults for archived v1-shaped snapshots, but the v2 admission handshake prevents old and new live predictors from mixing. Authority runs at 60 Hz, guests normally submit input at 20 Hz, and the host publishes snapshots at 12 Hz within a validated 10–15 Hz range. Clients buffer remote state, interpolate continuous Formula telemetry by tick, step discrete gear/shift state, and reconcile local prediction over a bounded history; recovery and layer transitions use explicit flags/layer fields.

## Reliable race events

Host authority validates countdown/start, bounded conventional inputs, snapshots, checkpoint/lap/finish state, disconnects, kicks, results, and rematch transitions. `RACE_EVENT` carries host-only race completion/rematch actions and identity-bound guest rematch intent; the backend emits `rematch_requested` only to the host. Duplicate or stale messages are rejected by `(room_epoch, sender, opcode, seq)`. Cosmetic sound/particles never determine rules.

## Room lifecycle

```text
CREATING → LOBBY → TRACK_SYNC → READY → COUNTDOWN → RACING → RESULTS → CLOSED
```

Only the host may configure/lock/kick/start, author the room track, or restart after results. The v2 authoritative race config is exactly `{laps: 1|3|5, collisions: bool}`. A real change resets every driver's Ready flag; the locked config is repeated in the synchronized countdown. `join_locked` is independent of countdown: it blocks new joins and circuit/rule/kick changes, permits existing verified members to acknowledge Ready, and is required before start. A guest rematch request is delivered only to the host; a host rematch moves `RESULTS` to `READY`/`TRACK_SYNC`, preserves the lock and verified manifest, clears snapshots/countdown, and resets all Ready flags. Backend/RPC code validates room code, membership, slot cap, state transition, and caller authority. Late or unready peers cannot enter a running simulation unless an explicitly tested spectate/resume path exists.

## Disconnect and background behavior

- The v2 reconnect window is 20 seconds in both client limits and the 20 Hz Nakama match loop.
- Rejoining peer proves session/membership, receives a reliable full snapshot, then resumes deltas.
- Reconnect-time manifest verification is idempotent: it may update that member's verification result but cannot demote `COUNTDOWN`, `RACING`, `RESULTS`, or `CLOSED` to a lobby phase.
- Lobby host departure transfers ownership to the oldest connected member; that policy does not apply once countdown or racing has begun.
- In-race host departure ends the v2 race cleanly with an explanation unless a later ADR and soak suite proves host migration safe.
- Backend unavailable/maintenance leaves offline play available and shows a retryable multiplayer error.

## Authority validation

Validate identity/membership, room state/epoch, allowed input range/rate, disabled legacy boost, snapshot publisher/range/rate, ordered checkpoints/laps, result order, payload size, hash/version, and request replay. Disconnect or quarantine repeated violations with a stable safe error code; do not expose internal secrets.

## Security and privacy

Use TLS/WSS outside local development. The current client keeps Nakama session/reconnect material in runtime memory; platform secure-store persistence is not implemented and must not be claimed. Never log auth tokens, database credentials, full install identifiers, private room codes, or reconnect secrets. Short room codes are rate-limited, expire, and are not authorization by themselves. See `PRIVACY_DATA_MAP.md`.

## Required verification

The release suite must cover create/join/invalid code, explicit lock/unlock, full/locked room, ready gate, same-room Track Studio return, inline track limits, malformed definitions, compatibility/hash mismatch, synchronized start, duplicate/out-of-order input, 12-player bandwidth, prediction correction, latency/jitter/loss, background/socket-drop reconnect, reconnect-time re-verification, host departure, result authority, rematch authority, backend loss, and protocol fuzzing. Exact results and evidence paths are recorded only in `TEST_REPORT.md`; this contract does not turn implementation presence into a PASS.
