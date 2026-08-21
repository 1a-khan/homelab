#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
policy_name="iac-cloudflare"
username="iac"

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

printf "Cloudflare API token for IaC: "
IFS= read -r -s cloudflare_api_token
printf "\n"

if [[ -z "${cloudflare_api_token}" ]]; then
  echo "No Cloudflare API token entered; aborting." >&2
  exit 1
fi

printf "New password for OpenBao user '${username}': "
IFS= read -r -s iac_password
printf "\n"

if [[ -z "${iac_password}" ]]; then
  echo "No iac password entered; aborting." >&2
  exit 1
fi

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" bao auth enable userpass >/dev/null 2>&1 || true

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" "POLICY_NAME=${policy_name}" \
  sh -lc 'bao policy write "${POLICY_NAME}" -' <<'POLICY'
path "apps/data/iac/cloudflare" {
  capabilities = ["read"]
}

path "apps/metadata/iac" {
  capabilities = ["read", "list"]
}

path "apps/metadata/iac/cloudflare" {
  capabilities = ["read"]
}
POLICY

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" "CLOUDFLARE_API_TOKEN=${cloudflare_api_token}" \
  sh -lc 'bao kv put apps/iac/cloudflare CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN}" >/dev/null'

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" "IAC_PASSWORD=${iac_password}" "POLICY_NAME=${policy_name}" \
  sh -lc 'bao write auth/userpass/users/iac password="${IAC_PASSWORD}" policies="${POLICY_NAME}" >/dev/null'

unset cloudflare_api_token
unset iac_password

echo "Cloudflare API token stored in OpenBao at apps/iac/cloudflare."
echo "OpenBao user '${username}' is ready with policy '${policy_name}'."
