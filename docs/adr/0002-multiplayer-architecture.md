# ADR 0002: Multiplayer Architecture

- Status: Accepted for v1 implementation
- Date: 2026-07-23
- Implementation status: implemented as a local candidate; final test outcomes and public/mobile gates are tracked separately

## Context

Private internet rooms must support up to 12 friends without router configuration, including a host-drawn deterministic track. Offline play must remain independent. Version 1 is casual, with no ranked economy or strong anti-cheat, so delivery simplicity and mobile viability outweigh hostile-host protection.

## Decision

Use **Nakama 3.40.0 with PostgreSQL 17.9-alpine3.23** as the local backend candidate and the official Nakama Godot SDK 3.4.0. The immutable server/database image digests live in `backend/UPSTREAM.json`; the vendored SDK is pinned to commit `14b7f7078a9822c15b0424624e4c883c87730cee`. Use relayed client-host authority for races:

- Nakama: anonymous sessions, short-code RPC/mapping, room/match presence/lifecycle, relayed data, transient canonical track manifest, compatibility admission, lock/ready/rematch policy, and authoritative membership/cosmetics.
- Host client: fixed-step vehicle/AI/race simulation, bounded input validation, checkpoint/lap/result authority, snapshots.
- Guest: sends sequenced inputs, predicts its local car, interpolates remote cars, reconciles to snapshots.
- Track: host sends canonical `TrackDefinition`; every peer validates/generates and reports exact schema/generator/hash before ready.
- Offline: uses the same local simulation without Nakama.

The repository implements a loopback-only Docker Compose stack, JavaScript RPC/match module, Godot transport/session/race adapters, fake transport, clean-room E2E and 12-client runners, and an isolated local backup/restore drill. Exact outcomes are recorded only in `TEST_REPORT.md`. A local pass would still not establish mobile multi-peer behavior, public TLS/ingress, production secrets, retention, monitoring, distributed load, or disaster recovery.

## Failure decision

Lobby ownership transfers to the oldest connected member. Once countdown/racing/results authority is active, simulation-host departure ends the v1 room cleanly with an explicit reason; no seamless race-host migration is claimed. A disconnected guest has a fixed 20-second reconnect window, must prove its rotated reconnect token and membership, receives authoritative room/full-race state, and re-verifies the track without demoting an active phase. Backend failure disables multiplayer entry/retry but never offline play.

## Alternatives considered

### Nakama authoritative match logic

Stronger authority and host-departure handling, but requires duplicating/porting the game simulation or maintaining a server-specific deterministic model. Higher initial complexity and cost. Deferred for ranked/competitive requirements.

### Godot ENet with dedicated server

Can reuse Godot simulation and offer full authority, but requires deployment/discovery/relay/NAT operations and always-on capacity. Credible later option if cheating or host continuity becomes important; rejected for v1 simplicity.

### Direct peer/ENet host

Simplest local networking, but private internet rooms would face NAT/router setup and weaker lifecycle/discovery. Rejected.

### Managed proprietary multiplayer service

Could reduce operations, but introduces cost, terms, lock-in, account approval, and uncertain Godot/mobile integration. No concrete alternative currently beats the open-source candidate. Re-evaluate only with written pricing/privacy/SDK evidence and owner approval.

## Consequences

- Private rooms get internet relay and lifecycle services without making generated assets authoritative.
- V1 rooms support explicit host lock/unlock, same-room Track Studio return, fictional car/team authority, host-owned race rules, three-sector HUD timing, copied results without room secrets, and host-authorized rematches. Private-room AI fill remains excluded.
- Host CPU/network must handle 12 cars/peers; bandwidth, thermal, latency, loss, and mobile background behavior are release gates.
- A malicious host can cheat, censor, or falsify results. No ranked claims or valuable rewards are allowed under this model.
- In-race host loss is disruptive but explicit; lobby-only ownership transfer does not imply simulation-host migration.
- Nakama/PostgreSQL operations introduce secrets, migrations, backups, retention, monitoring, and privacy obligations.
- Production hosting/public exposure/cost, TLS/DNS, secrets, retention, monitoring, backend account deletion/export, physical-device multiplayer, and store credentials require owner approval and separate evidence.

## Revisit triggers

Ranked play or prizes; meaningful cheating reports; unacceptable host-loss rate; host device cannot meet 12-player performance; relay/SDK lacks required mobile behavior; Nakama/PostgreSQL operational burden exceeds a measured alternative; or cross-platform simulation cannot reconcile acceptably.

## References

- Nakama multiplayer models: <https://heroiclabs.com/docs/nakama/concepts/multiplayer/>
- Nakama Godot 4 client: <https://heroiclabs.com/docs/nakama/client-libraries/godot/>
- Nakama Docker Compose: <https://heroiclabs.com/docs/nakama/getting-started/install/docker/>
- Nakama release notes: <https://heroiclabs.com/docs/nakama/getting-started/release-notes/>
