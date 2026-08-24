#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
policy_name="iac-hetzner"
username="iac"

# shellcheck source=lib/openbao-login.sh
source "${repo_root}/scripts/lib/openbao-login.sh"

openbao_login_admin

printf "Hetzner Cloud API token for IaC: "
IFS= read -r -s hcloud_token
printf "\n"

if [[ -z "${hcloud_token}" ]]; then
  echo "No Hetzner API token entered; aborting." >&2
  exit 1
fi

printf "Password to set/confirm for OpenBao user '%s': " "${username}"
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
path "apps/data/iac/hetzner" {
  capabilities = ["read"]
}

path "apps/metadata/iac" {
  capabilities = ["read", "list"]
}

path "apps/metadata/iac/hetzner" {
  capabilities = ["read"]
}
POLICY

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" "HCLOUD_TOKEN=${hcloud_token}" \
  sh -lc 'bao kv put apps/iac/hetzner HCLOUD_TOKEN="${HCLOUD_TOKEN}" >/dev/null'

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" "IAC_PASSWORD=${iac_password}" \
  sh -lc 'bao write auth/userpass/users/iac password="${IAC_PASSWORD}" policies="iac-cloudflare,iac-hetzner" >/dev/null'

unset hcloud_token iac_password

echo "Hetzner Cloud API token stored in OpenBao at apps/iac/hetzner."
echo "OpenBao user '${username}' is ready with policies iac-cloudflare,iac-hetzner."
