#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
remote_host="${WINDMILL_VPS_HOST:-hetzner-prod}"
remote_env="${WINDMILL_COOLIFY_ENV:-/data/coolify/services/ngck8kk48wcgoc44kos444w8/.env}"
tmp_env="$(mktemp)"

cleanup_tmp() {
  rm -f "${tmp_env}"
}
trap cleanup_tmp EXIT

ssh "${remote_host}" "sudo sed -n '1,220p' '${remote_env}'" > "${tmp_env}"

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

get_env() {
  local key="$1"
  local value
  value="$(grep -E "^${key}=" "${tmp_env}" | tail -n 1 | cut -d= -f2- || true)"
  value="${value%\"}"
  value="${value#\"}"
  printf '%s' "${value}"
}

service_user_postgres="$(get_env SERVICE_USER_POSTGRES)"
service_password_postgres="$(get_env SERVICE_PASSWORD_POSTGRES)"
postgres_db="$(get_env POSTGRES_DB)"

if [[ -z "${service_user_postgres}" || -z "${service_password_postgres}" ]]; then
  echo "Missing SERVICE_USER_POSTGRES or SERVICE_PASSWORD_POSTGRES in Windmill .env." >&2
  exit 1
fi

postgres_db="${postgres_db:-windmill-db}"

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" \
      "SERVICE_USER_POSTGRES=${service_user_postgres}" \
      "SERVICE_PASSWORD_POSTGRES=${service_password_postgres}" \
      "POSTGRES_DB=${postgres_db}" \
  sh -lc 'bao kv put apps/windmill \
    SERVICE_USER_POSTGRES="${SERVICE_USER_POSTGRES}" \
    SERVICE_PASSWORD_POSTGRES="${SERVICE_PASSWORD_POSTGRES}" \
    POSTGRES_DB="${POSTGRES_DB}" >/dev/null'

unset service_user_postgres
unset service_password_postgres
unset postgres_db

echo "Windmill database credentials copied from VPS env into OpenBao path apps/windmill."
