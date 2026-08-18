#!/bin/sh
set -eu
umask 077

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
production_dir=$(unset CDPATH; cd -- "${script_dir}/.." && pwd)
env_path="${production_dir}/.env"
domain="${1:-multiplayer.neutale.com}"
acme_email="${2:-}"

if [ "${domain}" != "multiplayer.neutale.com" ]; then
  echo "The domain must match the hostname compiled into the mobile client." >&2
  exit 2
fi
case "${acme_email}" in
  *@*.*) ;;
  *)
    echo "Usage: $0 multiplayer.neutale.com acme-contact@example.com" >&2
    exit 2
    ;;
esac
if [ -e "${env_path}" ]; then
  echo "Refusing to replace existing production secrets at ${env_path}." >&2
  exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
  echo "OpenSSL is required to generate production secrets." >&2
  exit 1
fi

temporary_path=$(mktemp "${production_dir}/.env.new.XXXXXX")
cleanup() {
  rm -f "${temporary_path}"
}
trap cleanup EXIT HUP INT TERM

random_hex() {
  openssl rand -hex 32
}

{
  printf 'RACEGLYPH_DOMAIN=%s\n' "${domain}"
  printf 'ACME_EMAIL=%s\n' "${acme_email}"
  printf 'POSTGRES_DB=nakama\n'
  printf 'POSTGRES_USER=nakama\n'
  printf 'POSTGRES_PASSWORD=%s\n' "$(random_hex)"
  printf 'NAKAMA_SERVER_KEY=raceglyph_mobile_protocol_4\n'
  printf 'NAKAMA_SESSION_ENCRYPTION_KEY=%s\n' "$(random_hex)"
  printf 'NAKAMA_REFRESH_ENCRYPTION_KEY=%s\n' "$(random_hex)"
  printf 'NAKAMA_RUNTIME_HTTP_KEY=%s\n' "$(random_hex)"
  printf 'NAKAMA_CONSOLE_USERNAME=raceglyph_admin\n'
  printf 'NAKAMA_CONSOLE_PASSWORD=%s\n' "$(random_hex)"
  printf 'NAKAMA_CONSOLE_SIGNING_KEY=%s\n' "$(random_hex)"
} >"${temporary_path}"

chmod 600 "${temporary_path}"
mv "${temporary_path}" "${env_path}"
trap - EXIT HUP INT TERM
echo "Production environment created with mode 0600. Secret values were not printed."
