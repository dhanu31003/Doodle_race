# ADR 0002: Multiplayer Architecture

- Status: Superseded by protocol-4 cloud authority
- Date: 2026-07-23
- Implementation status: protocol-4 source and local real-backend tests implemented; public/mobile gates are tracked separately

## Context

Private internet rooms must support up to 12 friends without router configuration, including a host-drawn deterministic track. Offline play must remain independent. Version 1 is casual, with no ranked economy or strong anti-cheat, so delivery simplicity and mobile viability outweigh hostile-host protection.

## Decision

Use **Nakama 3.40.0 with PostgreSQL 17.9-alpine3.23** and the official Nakama Godot SDK 3.4.0. The immutable image digests live in `backend/UPSTREAM.json`; the vendored SDK is pinned to commit `14b7f7078a9822c15b0424624e4c883c87730cee`. Protocol 4 moves online race authority into the Nakama match runtime:

- Nakama: anonymous sessions, short-code RPC/mapping, room/match lifecycle, compatibility, lock/ready/rematch policy, authoritative membership, 60 Hz vehicle/race simulation, checkpoint/lap/result authority, and 20 Hz snapshots.
- Every phone: sends sequenced bounded controls, predicts its local car immediately, interpolates remote cars, and reconciles to server snapshots. The creator is a lobby administrator, not a simulation host.
- Track: the creator sends canonical `TrackDefinition` plus hashed bounded authority geometry; the server validates it and every peer regenerates and compares it before Ready.
- Offline: uses the same local simulation without Nakama.

The repository implements local and TLS production Compose stacks, a JavaScript cloud race runtime, Godot transport/session/prediction adapters, fake transport, real E2E and 12-client runners, and an isolated backup/restore drill. Exact outcomes are recorded only in `TEST_REPORT.md`. A local pass still does not establish public DNS/hosting, physical mobile-radio behavior, production retention/monitoring, or disaster recovery.

## Failure decision

Lobby administration transfers to the oldest connected member. During countdown/racing/results, creator departure marks that car DNF, transfers administration, and leaves the cloud simulation and room epoch running. A disconnected phone has a fixed 20-second reconnect window, proves its rotated token and membership, receives authoritative room/full-race state, and re-verifies the track without demoting an active phase. Backend failure disables multiplayer entry/retry but never offline play.

## Alternatives considered

### Relayed client-host authority

Lower backend CPU and simpler simulation reuse, but makes one phone the connection/authority bottleneck, allows result forgery, and ends or migrates poorly on creator loss. This was the protocol-3 implementation and is rejected for the mobile cloud requirement.

### Godot ENet with dedicated server

Can reuse Godot simulation and offer full authority, but requires deployment/discovery/relay/NAT operations and always-on capacity. Credible later option if cheating or host continuity becomes important; rejected for v1 simplicity.

### Direct peer/ENet host

Simplest local networking, but private internet rooms would face NAT/router setup and weaker lifecycle/discovery. Rejected.

### Managed proprietary multiplayer service

Could reduce operations, but introduces cost, terms, lock-in, account approval, and uncertain Godot/mobile integration. No concrete alternative currently beats the open-source candidate. Re-evaluate only with written pricing/privacy/SDK evidence and owner approval.

## Consequences

- Private rooms get cloud-owned simulation and lifecycle services without making generated visual assets authoritative.
- V1 rooms support explicit administrator lock/unlock, same-room Track Studio return, fictional car/team authority, administrator-owned race rules, three-sector HUD timing, copied cloud results without room secrets, and administrator-authorized rematches. Private-room AI fill remains excluded.
- Backend CPU/network must handle every active room; capacity, latency, loss, and mobile background behavior are release gates.
- Phones cannot forge snapshots/results, though commercial anti-cheat and ranked security remain future work.
- Creator loss does not stop the race; full backend loss still does.
- Nakama/PostgreSQL operations introduce secrets, migrations, backups, retention, monitoring, and privacy obligations.
- Production hosting/public exposure/cost, TLS/DNS, secrets, retention, monitoring, backend account deletion/export, physical-device multiplayer, and store credentials require owner approval and separate evidence.

## Revisit triggers

Ranked play or prizes; meaningful cheating reports; unacceptable backend-loss rate; cloud capacity cannot meet concurrent-room performance; SDK lacks required mobile behavior; Nakama/PostgreSQL operational burden exceeds a measured alternative; or client prediction cannot reconcile acceptably.

## References

- Nakama multiplayer models: <https://heroiclabs.com/docs/nakama/concepts/multiplayer/>
- Nakama Godot 4 client: <https://heroiclabs.com/docs/nakama/client-libraries/godot/>
- Nakama Docker Compose: <https://heroiclabs.com/docs/nakama/getting-started/install/docker/>
- Nakama release notes: <https://heroiclabs.com/docs/nakama/getting-started/release-notes/>
