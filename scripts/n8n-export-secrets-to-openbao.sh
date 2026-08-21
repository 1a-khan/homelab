#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
remote_env="/data/coolify/services/m40w04kco0ww0wk0c4wc4w04/.env"
tmp_env="$(mktemp)"
trap 'rm -f "${tmp_env}"' EXIT

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin
trap 'rm -f "${tmp_env}"; openbao_revoke_login_token' EXIT

ssh hetzner-prod "sudo sed -n '1,220p' '${remote_env}'" > "${tmp_env}"

get_env() {
  local key="$1"
  local value
  value="$(awk -F= -v k="${key}" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "${tmp_env}")"
  if [[ -z "${value}" ]]; then
    echo "Missing ${key} in ${remote_env}" >&2
    exit 1
  fi
  printf '%s' "${value}"
}

SERVICE_USER_POSTGRES="$(get_env SERVICE_USER_POSTGRES)"
SERVICE_PASSWORD_POSTGRES="$(get_env SERVICE_PASSWORD_POSTGRES)"
N8N_ENCRYPTION_KEY="$(get_env N8N_ENCRYPTION_KEY)"
N8N_RUNNERS_AUTH_TOKEN="$(get_env N8N_RUNNERS_AUTH_TOKEN)"
N8N_SKIP_AUTH_ON_OAUTH_CALLBACK="$(get_env N8N_SKIP_AUTH_ON_OAUTH_CALLBACK)"

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" \
      "SERVICE_USER_POSTGRES=${SERVICE_USER_POSTGRES}" \
      "SERVICE_PASSWORD_POSTGRES=${SERVICE_PASSWORD_POSTGRES}" \
      "N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}" \
      "N8N_RUNNERS_AUTH_TOKEN=${N8N_RUNNERS_AUTH_TOKEN}" \
      "N8N_SKIP_AUTH_ON_OAUTH_CALLBACK=${N8N_SKIP_AUTH_ON_OAUTH_CALLBACK}" \
  sh -lc 'bao kv put apps/n8n \
    SERVICE_USER_POSTGRES="${SERVICE_USER_POSTGRES}" \
    SERVICE_PASSWORD_POSTGRES="${SERVICE_PASSWORD_POSTGRES}" \
    N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY}" \
    N8N_RUNNERS_AUTH_TOKEN="${N8N_RUNNERS_AUTH_TOKEN}" \
    N8N_SKIP_AUTH_ON_OAUTH_CALLBACK="${N8N_SKIP_AUTH_ON_OAUTH_CALLBACK}"'

echo "n8n secrets copied from VPS env into OpenBao path apps/n8n."
