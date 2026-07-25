# Backend Operations

Status: **implemented local-candidate runbook**. Compose configuration, the JavaScript RPC/match module, health checks, clean-room E2E/load runners, and an isolated backup/restore drill exist. Their exact candidate outcomes belong in `TEST_REPORT.md`; nothing here claims staging, TLS, production retention, encrypted off-site backups, or a public service.

## Selected candidate

- Nakama server: `registry.heroiclabs.com/heroiclabs/nakama:3.40.0@sha256:92fb184e3271be12fd4d239766afb285322a50aaf769a59433445d59624c78cd`
- Database: `postgres:17.9-alpine3.23@sha256:c7526c0f6c3f30260a563d7bcf8ad778effac59a44f8ffa86678c35418338609`
- Local container runtime observed: Docker 29.3.1
- Client: official Nakama Godot SDK `3.4.0`, vendored at commit `14b7f7078a9822c15b0424624e4c883c87730cee`; upstream source and license are recorded in `game/network/nakama/vendor/heroiclabs_nakama_godot/UPSTREAM.json`.

The image tags, digests, upstream tags/commits, and licenses are recorded in `backend/UPSTREAM.json`. RaceGlyph selects PostgreSQL for its local candidate because it is sufficient for private casual rooms. These pins and a local stack are not proof of a maintained deployment.

Before staging, refresh dependency/SBOM and vulnerability evidence, re-verify the Nakama–Godot compatibility matrix, and approve any deliberate pin change through the release process.

## Intended responsibilities

Nakama provides anonymous session authentication, short-code room RPCs, membership/presence, relayed match traffic, and room lifecycle state. The client host simulates a v1 race. A canonical track definition is held only in transient match state and relayed to members; the v1 module does not provide a persistent user-track service. PostgreSQL persists Nakama accounts, devices, storage-backed room-code directory entries, and migration metadata. Generated geometry, decoration, and pixels never enter backend authority.

## Implemented layout

```text
backend/
  compose.yaml
  .env.example
  UPSTREAM.json
  config/nakama.yml
  modules/index.js
  ops/compose.backup-restore-drill.yaml
  scripts/healthcheck.sh
  scripts/validate_compose.sh
  scripts/run_local_e2e.sh
  scripts/run_local_12_client_load.sh
  scripts/run_backup_restore_drill.sh
```

There is no project-owned database schema in v1; Nakama applies its pinned migrations during container startup.

## Local service contract

| Service | Internal/public port | Exposure |
|---|---:|---|
| Nakama API/socket | 7350 | localhost in development; TLS ingress in staging/prod |
| Nakama console | 7351 | localhost only; never public without protected admin access |
| Nakama gRPC | 7349 | internal unless a documented client requires it |
| PostgreSQL | 5432 | compose network only |

## Local verification commands

Run from the repository root:

```sh
backend/scripts/validate_compose.sh
backend/scripts/run_local_e2e.sh
backend/scripts/run_local_12_client_load.sh
backend/scripts/run_backup_restore_drill.sh
```

The runners use `backend/.env.example` only inside uniquely named disposable local Compose projects, publish Nakama on loopback, remove volumes and temporary credentials/responses/dumps on exit, and retain only redacted evidence summaries where specified. Never reuse those placeholder values outside the disposable local drills.

## Configuration and secrets

- Commit `.env.example` with names and safe placeholders only.
- Supply database password, server key, session/refresh encryption keys, runtime HTTP key, console credentials, and TLS credentials through a secret manager or protected environment.
- Rotate all defaults before staging. Use independent secrets per environment.
- Never put tokens, private keys, keystores, signing certificates, production hostnames, or database dumps in Git or client resources.
- The client may contain the Nakama server key intended for client use, but it is not authorization; backend RPCs still verify authenticated identity, membership, and authority.

## Health and readiness

The local stack implements:

- PostgreSQL `pg_isready` health inside Compose and real SQL queries in the restore drill.
- Nakama CLI health in Compose plus the loopback HTTP `/healthcheck` probe.
- Explicit Nakama migration before process start.
- A local functional smoke that authenticates, invokes the versioned RPC/match module, exercises room/track/race relay behavior, and tears the stack down.

Staging still requires independent readiness that verifies the deployed image/config, migration state, runtime module, anonymous auth, create/code lookup/join/leave, relay round trip, expiry, and ingress/TLS behavior.

Do not send traffic until readiness succeeds. Include build/version in health metadata without exposing secrets.

## Logs and metrics

Nakama emits structured JSON service logs. Project module messages use stable safe error codes and avoid private room codes, reconnect material, tokens, credentials, install identifiers, and user-entered track names. Local E2E/load/restore runners fail on fatal/runtime diagnostics or credential/token-shaped retained output. A production log pipeline still needs approved fields, access controls, retention, and alerting.

Metrics require authentication/session failures, active rooms/players, RPC and relay latency, payload bytes, rate-limit rejections, disconnect reasons, database latency/pool saturation, CPU/memory, restarts, and backup age. Retention and alert thresholds remain a staging decision and must be recorded in the privacy map.

## Local backup/restore drill

`backend/scripts/run_backup_restore_drill.sh` creates a disposable account, quiesces source application writes, writes a PostgreSQL custom-format archive to a mode-`077` temporary directory, restores it into an isolated database/network/volume, checks identity/device/migration rows, and authenticates the restored device with `create=false`. The trap removes raw dumps, HTTP responses, service logs, and both disposable volumes; only a redacted metrics/checksum summary is eligible for `evidence/logs/`.

This deliberately local archive is **not encrypted, off-site, retained, scheduled, or an RPO/RTO demonstration**. It proves the mechanics exercised by a recorded run, not a production backup service.

## Production backup and restore

Before production:

1. Define encrypted PostgreSQL backups with explicit frequency, retention, destination, and owner.
2. Use a consistent `pg_dump`/provider snapshot compatible with the pinned PostgreSQL version.
3. Restore into an isolated environment, apply/check Nakama migrations, and run functional smoke tests.
4. Record recovery point objective, recovery time objective, checksum, duration, and evidence.
5. Test deletion/export semantics and ensure expired player data is removed from backups according to policy.

A production backup job is not “working” until its encrypted retained artifact passes an isolated restore drill under the approved provider, retention, deletion, and access-control policy.

## Upgrade and rollback

- Read Nakama and SDK release notes; verify supported server/common/runtime combinations.
- Back up and restore-test first, then run schema migration explicitly in staging.
- Roll forward one pinned version at a time; run compatibility, reconnect, load, and room tests.
- Keep the prior image/config and a database-compatible rollback plan. A destructive schema migration needs a restore-based rollback rehearsal.
- Block incompatible client builds through the protocol handshake with a clear update-required response.

## Production deployment gate

Requires owner approval for paid hosting/public exposure plus chosen region/provider, DNS, TLS, database sizing, secret manager, backups, monitoring, retention, budget, and incident owner. No public deployment or cost is authorized by this document.

Minimum release evidence: clean compose rebuild, migration status, dependency scan, health/readiness, auth/room/relay suite, 12-peer load/soak, restart/reconnect, database loss behavior, backup/restore drill, TLS validation, secret scan, and offline-client behavior during outage.

## Incident outline

1. Identify scope from safe diagnostic IDs and service metrics.
2. Preserve logs and announce only through owner-approved channels.
3. Degrade multiplayer cleanly; never impair offline mode.
4. Roll back application image/config when database compatibility permits, otherwise restore/roll forward under the documented plan.
5. Verify auth, room, relay, track transfer, reconnect, and data integrity.
6. Record timeline, root cause, player-data impact, and corrective test.

## References

- Heroic Labs Docker Compose: <https://heroiclabs.com/docs/nakama/getting-started/install/docker/>
- Nakama configuration: <https://heroiclabs.com/docs/nakama/getting-started/configuration/>
- Nakama release notes: <https://heroiclabs.com/docs/nakama/getting-started/release-notes/>
- Nakama Godot 4 client: <https://heroiclabs.com/docs/nakama/client-libraries/godot/>
