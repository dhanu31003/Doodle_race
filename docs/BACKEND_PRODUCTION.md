# Mobile Multiplayer Production Runbook

Status: **production topology implemented in source; cloud host, DNS, secrets, and two-phone verification still required**.

RaceGlyph mobile clients are compiled for `https://multiplayer.neutale.com:443`. Caddy terminates TLS and preserves Nakama WebSocket upgrades, Nakama owns anonymous authentication/private-room lifecycle and the 60 Hz authoritative race loop, and PostgreSQL persists accounts and room-directory state. Players need only the mobile app and an internet connection; no player PC or phone is the connection host.

All phones submit controls at up to 20 Hz and predict their own car immediately. Nakama advances three deterministic simulation steps per 20 Hz match tick and publishes server-owned snapshots. Clients reconcile to that state; they cannot publish snapshots or results. If the room creator leaves, lobby administration moves to the oldest connected player while the cloud race continues.

## AWS free-tier pilot

For the first internet pilot, use a new eligible AWS account in `ap-south-1` (Mumbai) and a free-tier-eligible EC2 instance. Current post-15-July-2025 AWS accounts receive credits and a free-plan window rather than an unlimited free server; verify eligibility and remaining credits in Billing before creating anything. A `t3.small`-class two-vCPU/two-GB instance is a practical private-test starting point, but it must be watched for memory, CPU-credit, disk, and network pressure. Move to four GB or separate PostgreSQL as soon as observed load needs it.

The account-bound checklist is [`../backend/production/aws/README.md`](../backend/production/aws/README.md).

Firebase Spark is not the race-server target. Its Realtime Database quotas are useful for small presence/config workloads, but Spark does not provide an always-running authoritative process and does not include Cloud Run/IaaS. Putting 60 Hz vehicle authority in database listeners would add latency, write volume, contention, and weak simulation ownership. Firebase services may be added later for analytics, crash reporting, or push notifications without entering the control path.

## Initial host

Use a dedicated Linux server, not a developer laptop or an unrelated production workload.

- Ubuntu 24.04 LTS or another maintained Docker host.
- Pilot: free-tier-eligible two-vCPU/two-GB EC2 with at least 30 GB storage, strict monitoring, and private test traffic only.
- Public baseline: 2 dedicated vCPU, 4 GB RAM, and at least 40 GB SSD; resize from measurements rather than assuming the pilot size is sufficient.
- Stable public IPv4; IPv6 is optional but must be tested if published.
- Docker Engine with Compose v2.
- TCP 22 restricted to administrator IPs; public TCP 80/443 and UDP 443 only.
- No public PostgreSQL, Nakama API, Nakama console, or Docker daemon ports.

Scale from observed concurrent rooms, relay bandwidth, database latency, CPU, memory, and disconnect rates. The starting size is an operational baseline, not a capacity guarantee.

## DNS and TLS

Create a proxied or DNS-only `A` record for `multiplayer.neutale.com` pointing to the dedicated server. The checked-in Caddy configuration obtains and renews a public certificate automatically using the contact in `ACME_EMAIL`. If Cloudflare proxying is enabled, verify WebSocket support and the origin certificate path before shipping.

Do not publish a private address, self-signed certificate, raw IP endpoint, or cleartext HTTP endpoint in a mobile release.

## Bootstrap

On the dedicated server, check out the immutable release commit and run from the repository root:

```sh
backend/production/scripts/generate_env.sh multiplayer.neutale.com ops@neutale.com
backend/production/scripts/validate.sh
docker compose --env-file backend/production/.env \
  -f backend/production/compose.yaml up -d --wait
backend/production/scripts/healthcheck.sh
```

The generated `.env` is mode `0600`, ignored by Git, and contains independent random database/session/runtime/console secrets. Secret values are never printed. `NAKAMA_SERVER_KEY` is deliberately different: it is the public application identifier embedded in every mobile client and is not an authorization boundary.

## Public acceptance

After DNS and TLS are live:

```sh
backend/production/scripts/run_public_e2e.sh
```

This drives the real HTTPS/WSS endpoint through anonymous device authentication, create/code-join, compatibility refusal, track synchronization, readiness, lock/start, server simulation/snapshots, reconnect, creator departure, kick, and cloud-owned results. It must pass without server fatal/runtime errors or client warnings.

Before Play production rollout, repeat on at least two physical phones on different networks and one 12-client controlled load. Confirm background/resume, 20-second reconnect, host loss, app-version mismatch, full-room refusal, latency/jitter/loss, battery/thermal behavior, and offline fallback.

## Operations

- Keep PostgreSQL and Nakama on the internal Compose network. Only Caddy publishes host ports.
- Restrict SSH by source IP and key; disable password/root login according to the host provider's baseline.
- Monitor TLS expiry, `/healthcheck`, container restarts, active rooms/players, authentication failures, relay latency/bytes, rate-limit rejections, database saturation, disk use, and backup age.
- Take encrypted daily PostgreSQL backups to a separate provider/account. Test restore into an isolated stack before launch and after material upgrades.
- Retain only approved operational fields. Caddy access logging is disabled because Nakama WebSocket authentication may include session material in the URI.
- Rotate database/session/runtime/console secrets through a controlled maintenance window. Changing `NAKAMA_SERVER_KEY` also requires a new mobile build.
- Deploy by immutable Git commit and pinned container digests. Keep the previous compose/source revision as the rollback target.

## Remaining external actions

The source repository cannot create even a free-plan AWS resource or DNS record without the owner's signed-in AWS account, explicit authorization, region/budget guardrail, and DNS access. Until those are supplied and the public smoke plus physical-phone matrix pass, `multiplayer.neutale.com` is a reserved endpoint rather than a live service.
