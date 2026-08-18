# Multiplayer Network Protocol

Status: **implemented v4 cloud-authoritative protocol with a production mobile endpoint topology**. This document describes the current wire and room semantics; test outcomes belong in `TEST_REPORT.md`. Android/iOS defaults point to `https://multiplayer.neutale.com:443`; the source topology is not evidence that DNS/hosting is live or that physical-device multiplayer has passed.

## Model

- Up to 12 friends in a private room. Optional AI fill is deferred from protocol v4; no client or backend may silently create AI occupants.
- Nakama authenticates anonymous installs, resolves short room codes, manages presence/match lifecycle, validates track geometry, simulates every online car, and owns snapshots/results.
- Every phone sends bounded controls only. No player's phone or PC is the race server, including the room creator.
- Local prediction applies the driver's input on the first render/physics frame; cloud corrections are reconciled over bounded history. Remote cars interpolate server snapshots.
- The authoritative match runs three 60 Hz physics steps inside each 20 Hz Nakama match tick and broadcasts server snapshots at 20 Hz. Network latency cannot be zero, but it is removed from the local steering/throttle response path.
- No ranked mode or prizes are claimed in v4. Cloud ownership rejects client-authored snapshots/results but is not a complete commercial anti-cheat system.

## Compatibility handshake

Before match admission, every create/join RPC carries and the backend validates:

```text
app_build, protocol_version, track_schema_version,
generator_version, platform
```

Current protocol version is `4` and the matching application build is `0.4.0`; the tuple also requires track schema `2` and generator `3`. Protocol 4 is the cloud-authority boundary: protocol-3 client-host rooms cannot mix with server-simulated rooms. An exact tuple is required before a room reservation or match presence is created. Unknown/unsupported values return `update_required`; the client presents a blocking update surface with an offline-play escape, and there is no silent downgrade. After admission, canonical definition hash, bounded authority geometry, and generation status travel in `TRACK_MANIFEST`/`GENERATION_REPORT` and gate Ready independently.

## Envelope

Every application message contains `protocol`, `opcode`, `room_epoch`, `sender_id`, `seq`, and payload. Tick-bound messages also contain `tick`; bounded request flows may include an optional `request_id`. Binary encoding may replace canonical JSON after golden cross-platform codecs exist; semantics and limits remain versioned.

- `room_epoch` changes whenever a room authority/session is recreated and rejects stale packets.
- `seq` is monotonic per sender/opcode and bounded to JavaScript's maximum safe integer. Protocol 4 does not wrap a live sequence.
- Server-assigned identity is used; a claimed payload identity never overrides transport identity.
- Strings, arrays, rates, numbers, and payload bytes are bounded before allocation/use.

## Opcode registry

| Opcode | Message | Delivery | Sender → receiver |
|---:|---|---|---|
| 1 | `HELLO` / compatibility (reserved; v4 admission uses authenticated RPC) | reliable | peer ↔ cloud |
| 2 | `ROOM_CONFIG` | reliable | cloud → peers |
| 3 | `TRACK_MANIFEST` | reliable | creator → cloud → peers |
| 4 | `TRACK_CHUNK` | reserved/unimplemented in v4 | — |
| 5 | `GENERATION_REPORT` | reliable | peer → cloud |
| 6 | `READY_STATE` | reliable | peer ↔ cloud |
| 7 | `START_AT_TICK` | reliable | cloud → peers |
| 8 | `INPUT_FRAME` | unreliable/sequenced | peer → cloud |
| 9 | `STATE_SNAPSHOT` | unreliable/sequenced | cloud → peers |
| 10 | `RACE_EVENT` | reliable | cloud → peers |
| 11 | `COSMETIC_EVENT` | unreliable/sequenced | host/peer → peers |
| 12 | `PING_SAMPLE` | unreliable | peer ↔ cloud |
| 13 | `RESUME_REQUEST` / `RESUME_STATE` | reliable | peer ↔ cloud |
| 14 | `ROOM_ENDED` | reliable | cloud → peers |
| 15 | `ERROR` | reliable | cloud → peer |

Opcode numbers are reserved by this document and must not be reused with different semantics inside protocol 4.

## Track transfer and ready gate

The creator sends a canonical `TrackDefinition`, never generated road/scenery/pixels. The v4 `TRACK_MANIFEST` carries the complete schema-2 definition plus a bounded, quantized `authority_path`: at most 512 centreline samples, width, length, start transform, road surface, seed, and a SHA-256 path hash. The cloud validates and uses that geometry; every receiver compiles locally and requires an exact authority-path match before reporting success. Start is enabled only when every required participant has a successful matching report and is ready.

The canonical definition cap is `32,768` bytes and the application-envelope cap is `65,536` bytes. A schema-v2 definition therefore travels inline; opcode 4 remains reserved and no released client depends on chunk assembly. Compression or chunking would require a versioned protocol change plus decompressed-size, ordering, and ratio caps.

## Input and snapshots

`INPUT_FRAME` contains the envelope tick/sequence plus `steering`, `throttle`, `brake`, legacy `boost`, and `ack_host_tick`. Steering is an integer in `[-1000,1000]`; throttle and brake are integers in `[0,1000]`. Protocol 4 retains `boost` solely for structural compatibility: it is always `false`, and both client and cloud reject `true`. Inputs are normally submitted at 20 Hz, with a hard maximum of 20 frames per sender per second; stale, future, duplicate, malformed, and over-rate frames fail explicitly.

`STATE_SNAPSHOT` is accepted only from sender `server`. It contains authoritative tick and, per active car, slot, quantized pose/velocity, completed lap, next checkpoint, collision fields, airborne state, Formula telemetry, and contact data. Clients are forbidden to publish snapshots or results. The cloud runs at 60 Hz and publishes at 20 Hz. Phones buffer remote state, interpolate telemetry, and reconcile their immediately predicted local car over bounded history; hard corrections remain available for recovery and invalid divergence.

## Reliable race events

Cloud authority validates countdown/start, inputs, snapshots, checkpoint/lap/finish state, disconnects, kicks, results, and rematch transitions. The room administrator may lock/configure/start/rematch but cannot author race state. Duplicate or stale messages are rejected by `(room_epoch, sender, opcode, seq)`. Cosmetic sound/particles never determine rules.

## Room lifecycle

```text
CREATING → LOBBY → TRACK_SYNC → READY → COUNTDOWN → RACING → RESULTS → CLOSED
```

Only the current room administrator may configure/lock/kick/start, author the room track, or restart after results. The authoritative race config is exactly `{laps: 1|3|5, collisions: bool}`. A real change resets every driver's Ready flag; the locked config is repeated in the synchronized countdown. `join_locked` blocks new joins and circuit/rule/kick changes, permits verified members to acknowledge Ready, and is required before start. A guest rematch request is delivered to the administrator; an authorized rematch moves `RESULTS` to `READY`/`TRACK_SYNC`, preserves the lock and manifest, clears simulation/countdown, and resets all Ready flags. Backend/RPC code validates room code, membership, slot cap, state transition, and caller authority. Late or unready peers cannot enter a running simulation unless an explicitly tested spectate/resume path exists.

## Disconnect and background behavior

- The v2 reconnect window is 20 seconds in both client limits and the 20 Hz Nakama match loop.
- Rejoining peer proves session/membership, receives a reliable full snapshot, then resumes deltas.
- Reconnect-time manifest verification is idempotent: it may update that member's verification result but cannot demote `COUNTDOWN`, `RACING`, `RESULTS`, or `CLOSED` to a lobby phase.
- Room-administrator departure transfers lobby controls to the oldest connected member.
- During countdown/racing/results, creator departure marks only that car DNF, transfers administration, and leaves the cloud simulation and room epoch running.
- Backend unavailable/maintenance leaves offline play available and shows a retryable multiplayer error.

## Authority validation

Validate identity/membership, room state/epoch, allowed input range/rate, disabled legacy boost, snapshot publisher/range/rate, ordered checkpoints/laps, result order, payload size, hash/version, and request replay. Disconnect or quarantine repeated violations with a stable safe error code; do not expose internal secrets.

## Security and privacy

Use TLS/WSS outside local development. The current client keeps Nakama session/reconnect material in runtime memory; platform secure-store persistence is not implemented and must not be claimed. Never log auth tokens, database credentials, full install identifiers, private room codes, or reconnect secrets. Short room codes are rate-limited, expire, and are not authorization by themselves. See `PRIVACY_DATA_MAP.md`.

## Required verification

The release suite must cover create/join/invalid code, explicit lock/unlock, full/locked room, ready gate, same-room Track Studio return, inline track limits, malformed definitions, compatibility/hash mismatch, synchronized start, duplicate/out-of-order input, 12-player bandwidth, prediction correction, latency/jitter/loss, background/socket-drop reconnect, reconnect-time re-verification, host departure, result authority, rematch authority, backend loss, and protocol fuzzing. Exact results and evidence paths are recorded only in `TEST_REPORT.md`; this contract does not turn implementation presence into a PASS.
