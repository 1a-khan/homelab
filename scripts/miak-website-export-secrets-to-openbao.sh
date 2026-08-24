#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
container="uoow44sg0w4w4gcko8ok88o0-001131891985"
secret_path="apps/miak-website"

# shellcheck source=lib/openbao-login.sh
source "${repo_root}/scripts/lib/openbao-login.sh"

tmp_env="$(mktemp)"
cleanup_tmp() {
  rm -f "${tmp_env}"
}
trap cleanup_tmp EXIT

ssh hetzner-prod \
  "sudo docker inspect ${container} --format '{{json .Config.Env}}'" |
  jq -r '.[]' >"${tmp_env}"

env_value() {
  local name="$1"
  local value
  value="$(grep -E "^${name}=" "${tmp_env}" | sed -E "s/^${name}=//" || true)"
  if [[ -z "${value}" ]]; then
    echo "Missing ${name} in website container env." >&2
    exit 1
  fi
  printf '%s' "${value}"
}

SECRET_KEY_BASE="$(env_value SECRET_KEY_BASE)"
MAKE_WEBHOOK_API_KEY="$(env_value MAKE_WEBHOOK_API_KEY)"
TURNSTILE_SECRET_KEY="$(env_value TURNSTILE_SECRET_KEY)"
TURNSTILE_SITE_KEY="$(env_value TURNSTILE_SITE_KEY)"
export SECRET_KEY_BASE MAKE_WEBHOOK_API_KEY TURNSTILE_SECRET_KEY TURNSTILE_SITE_KEY

openbao_login_admin admin
trap 'cleanup_tmp; openbao_revoke_login_token' EXIT

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env \
    "BAO_TOKEN=${BAO_TOKEN}" \
    "SECRET_KEY_BASE=${SECRET_KEY_BASE}" \
    "MAKE_WEBHOOK_API_KEY=${MAKE_WEBHOOK_API_KEY}" \
    "TURNSTILE_SECRET_KEY=${TURNSTILE_SECRET_KEY}" \
    "TURNSTILE_SITE_KEY=${TURNSTILE_SITE_KEY}" \
  sh -lc '
    bao kv put apps/miak-website \
      SECRET_KEY_BASE="${SECRET_KEY_BASE}" \
      MAKE_WEBHOOK_API_KEY="${MAKE_WEBHOOK_API_KEY}" \
      TURNSTILE_SECRET_KEY="${TURNSTILE_SECRET_KEY}" \
      TURNSTILE_SITE_KEY="${TURNSTILE_SITE_KEY}" >/dev/null
  '

unset SECRET_KEY_BASE MAKE_WEBHOOK_API_KEY TURNSTILE_SECRET_KEY TURNSTILE_SITE_KEY

echo "miak-website secrets copied from VPS env into OpenBao path ${secret_path}."
