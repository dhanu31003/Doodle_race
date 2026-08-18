# Backend Local QA

These drills are deliberately local-only. They create uniquely named Compose projects, use disposable volumes, publish Nakama only on `127.0.0.1`, retain no database dump or session response, and tear everything down on success, failure, or interruption.

## Real 12-client cloud-authority smoke

```sh
backend/scripts/run_local_12_client_load.sh
```

The runner starts a clean Nakama/PostgreSQL stack, authenticates 13 distinct device sessions, admits exactly 12, verifies the thirteenth receives `room_full`, synchronizes one canonical track/authority path, proves the all-ready start gate, submits 55 phone inputs, and observes 36 cloud snapshot deliveries with non-zero server-owned movement. Any Godot warning, error, resource/ObjectDB leak, incomplete metric, backend panic/fatal/error, JavaScript exception, or token/credential-shaped log output fails the run.

## PostgreSQL backup and isolated restore drill

```sh
backend/scripts/run_backup_restore_drill.sh
```

The runner creates an account through source Nakama, stops source application writes, creates a PostgreSQL custom-format archive, restores it into a distinct network and volume, verifies the account/device relationship and migration metadata, then boots a separate restored Nakama and authenticates the existing device with `create=false`. The dump, HTTP responses, and raw service logs remain in a temporary directory and are deleted by the exit trap. Only a redacted metric summary and checksums are retained under ignored `evidence/logs/`.

Both commands require a Compose v2-compatible CLI; they prefer the Docker plugin and fall back to the standalone `docker-compose` command. They are development evidence, not proof of production TLS, hosted secrets, encrypted off-site backup retention, distributed load, disaster recovery RPO/RTO, or public-service operations.
