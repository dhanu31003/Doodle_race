#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
backend_dir=$(unset CDPATH; cd -- "${script_dir}/.." && pwd)
project_dir=$(unset CDPATH; cd -- "${backend_dir}/.." && pwd)
compose_file="${backend_dir}/ops/compose.backup-restore-drill.yaml"
env_file="${backend_dir}/.env.example"
compose_project="raceglyph-restore-${RANDOM}-$$"
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/raceglyph-restore-drill.XXXXXX")
dump_file="${temp_dir}/nakama.dump"
source_response="${temp_dir}/source-auth.json"
restore_response="${temp_dir}/restore-auth.json"
service_log="${temp_dir}/services.log"
evidence_dir="${project_dir}/evidence/logs"
current_step="initialization"
started_at=$(python3 -c 'import time; print(time.monotonic_ns() // 1000000)')
compose_command=()

find_free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

compose() {
  "${compose_command[@]}" -p "${compose_project}" --env-file "${env_file}" -f "${compose_file}" "$@"
}

cleanup() {
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf "${temp_dir}"
}

on_error() {
  echo "Backup/restore drill failed during: ${current_step}." >&2
}
trap on_error ERR
trap cleanup EXIT HUP INT TERM

if docker compose version >/dev/null 2>&1; then
  compose_command=(docker compose)
elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
  compose_command=(docker-compose)
else
  echo "A Compose v2-compatible Docker CLI is required for the isolated backup/restore drill." >&2
  exit 2
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required for functional restored-account verification." >&2
  exit 2
fi

set -a
# shellcheck disable=SC1090
source "${env_file}"
set +a
export SOURCE_NAKAMA_API_PORT="${SOURCE_NAKAMA_API_PORT:-$(find_free_port)}"
export RESTORE_NAKAMA_API_PORT="${RESTORE_NAKAMA_API_PORT:-$(find_free_port)}"
if [[ "${SOURCE_NAKAMA_API_PORT}" == "${RESTORE_NAKAMA_API_PORT}" ]]; then
  echo "Source and restore Nakama ports must differ." >&2
  exit 2
fi

current_step="disposable source startup"
compose down --volumes --remove-orphans >/dev/null 2>&1 || true
compose up -d --wait source-db source-nakama >"${temp_dir}/source-up.log" 2>&1

current_step="source functional seed"
source_status=$(curl --silent --show-error --output "${source_response}" --write-out '%{http_code}' \
  --user "${NAKAMA_SERVER_KEY}:" \
  --header 'Content-Type: application/json' \
  --request POST \
  --data '{"id":"raceglyph-restore-drill-device-0001","vars":{"purpose":"local_restore_drill"}}' \
  "http://127.0.0.1:${SOURCE_NAKAMA_API_PORT}/v2/account/authenticate/device?create=true&username=restore_drill_user")
if [[ "${source_status}" != "200" ]]; then
  echo "Source Nakama account seed returned HTTP ${source_status}." >&2
  exit 1
fi
source_users=$(compose exec -T source-db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Atqc \
  "SELECT count(*) FROM users WHERE username = 'restore_drill_user';")
source_devices=$(compose exec -T source-db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Atqc \
  "SELECT count(*) FROM user_device WHERE id = 'raceglyph-restore-drill-device-0001';")
if [[ "${source_users}" != "1" || "${source_devices}" != "1" ]]; then
  echo "Source Nakama seed did not create exactly one linked account and device." >&2
  exit 1
fi

current_step="quiesced PostgreSQL backup"
compose stop source-nakama >"${temp_dir}/source-stop.log" 2>&1
compose exec -T source-db pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  --format=custom --no-owner --no-privileges >"${dump_file}"
compose exec -T source-db pg_restore --list <"${dump_file}" >"${temp_dir}/dump-list.txt"
if [[ ! -s "${dump_file}" || ! -s "${temp_dir}/dump-list.txt" ]]; then
  echo "PostgreSQL backup or archive manifest is empty." >&2
  exit 1
fi
backup_bytes=$(wc -c <"${dump_file}" | tr -d '[:space:]')
backup_sha256=$(sha256sum "${dump_file}" | cut -d ' ' -f 1)

current_step="isolated PostgreSQL restore"
compose up -d --wait restore-db >"${temp_dir}/restore-db-up.log" 2>&1
compose exec -T restore-db pg_restore -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  --single-transaction --exit-on-error --no-owner --no-privileges <"${dump_file}"
restored_users=$(compose exec -T restore-db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Atqc \
  "SELECT count(*) FROM users WHERE username = 'restore_drill_user';")
restored_devices=$(compose exec -T restore-db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Atqc \
  "SELECT count(*) FROM user_device WHERE id = 'raceglyph-restore-drill-device-0001';")
linked_devices=$(compose exec -T restore-db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Atqc \
  "SELECT count(*) FROM user_device d JOIN users u ON u.id = d.user_id WHERE d.id = 'raceglyph-restore-drill-device-0001' AND u.username = 'restore_drill_user';")
migration_rows=$(compose exec -T restore-db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Atqc \
  "SELECT count(*) FROM migration_info;")
if [[ "${restored_users}" != "${source_users}" || "${restored_devices}" != "${source_devices}" ||
      "${linked_devices}" != "1" || ! "${migration_rows}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Restored PostgreSQL identity or migration data does not match the quiesced source." >&2
  exit 1
fi

current_step="restored Nakama functional authentication"
compose up -d --wait restore-nakama >"${temp_dir}/restore-nakama-up.log" 2>&1
restore_status=$(curl --silent --show-error --output "${restore_response}" --write-out '%{http_code}' \
  --user "${NAKAMA_SERVER_KEY}:" \
  --header 'Content-Type: application/json' \
  --request POST \
  --data '{"id":"raceglyph-restore-drill-device-0001"}' \
  "http://127.0.0.1:${RESTORE_NAKAMA_API_PORT}/v2/account/authenticate/device?create=false")
if [[ "${restore_status}" != "200" ]]; then
  echo "Restored Nakama create=false authentication returned HTTP ${restore_status}." >&2
  exit 1
fi
post_auth_users=$(compose exec -T restore-db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Atqc \
  "SELECT count(*) FROM users WHERE username = 'restore_drill_user';")
if [[ "${post_auth_users}" != "1" ]]; then
  echo "Restored functional authentication unexpectedly changed account cardinality." >&2
  exit 1
fi

current_step="diagnostic and credential scan"
compose logs --no-color >"${service_log}" 2>&1
if grep -E '"level":"(panic|fatal|error)"|(^|[[:space:]])(PANIC|FATAL|ERROR)(:|[[:space:]])|JavaScript[^[:cntrl:]]*(error|exception)' \
    "${service_log}" >/dev/null 2>&1; then
  echo "A source or restored service emitted a fatal/error diagnostic." >&2
  exit 1
fi
if grep -F -e "${POSTGRES_PASSWORD}" \
    -e "${NAKAMA_SERVER_KEY}" \
    -e "${NAKAMA_SESSION_ENCRYPTION_KEY}" \
    -e "${NAKAMA_REFRESH_ENCRYPTION_KEY}" \
    -e "${NAKAMA_RUNTIME_HTTP_KEY}" \
    -e "${NAKAMA_CONSOLE_PASSWORD}" \
    -e "${NAKAMA_CONSOLE_SIGNING_KEY}" \
    "${service_log}" "${temp_dir}"/*.log >/dev/null 2>&1; then
  echo "A disposable credential appeared in service output; evidence was not retained." >&2
  exit 1
fi
if grep -E 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}' \
    "${service_log}" "${temp_dir}"/*.log >/dev/null 2>&1; then
  echo "A session-like token appeared in service output; evidence was not retained." >&2
  exit 1
fi

finished_at=$(python3 -c 'import time; print(time.monotonic_ns() // 1000000)')
elapsed_ms=$((finished_at - started_at))
mkdir -p "${evidence_dir}"
timestamp=$(date -u +'%Y%m%dT%H%M%SZ')
evidence_log="${evidence_dir}/postgres-backup-restore-${timestamp}.log"
{
  echo "PASS postgres_backup_restore_functional"
  echo "RESTORE_METRICS checks=12 source_users=${source_users} restored_users=${restored_users} linked_devices=${linked_devices} migration_rows=${migration_rows} backup_bytes=${backup_bytes} backup_sha256=${backup_sha256} elapsed_ms=${elapsed_ms}"
  echo "RESTORE_DIAGNOSTICS service_errors=0 secret_hits=0 token_hits=0 retained_session_responses=0 retained_database_dumps=0"
  echo "RESTORE_SCOPE local_only=true source_volume=disposable restore_volume=disposable restored_auth_create=false"
} >"${evidence_log}"
sha256sum "${evidence_log}" >"${evidence_log}.sha256"
cat "${evidence_log}"
echo "RESTORE_EVIDENCE path=${evidence_log} sha256=$(cut -d ' ' -f 1 "${evidence_log}.sha256")"
