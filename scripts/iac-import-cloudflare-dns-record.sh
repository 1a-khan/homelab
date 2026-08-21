#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
username="iac"

resource_address="${1:-}"
zone_id="${2:-}"
record_name="${3:-}"

if [[ -z "${resource_address}" || -z "${zone_id}" || -z "${record_name}" ]]; then
  echo "Usage: scripts/iac-import-cloudflare-dns-record.sh <terraform-resource-address> <zone-id> <record-name>" >&2
  echo "Example: scripts/iac-import-cloudflare-dns-record.sh cloudflare_dns_record.n8n_prod 0c7c... n8n.miak-it.com" >&2
  exit 1
fi

client_token=""
cleanup() {
  if [[ -n "${client_token}" ]]; then
    kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
      env "BAO_TOKEN=${client_token}" bao token revoke -self >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

printf "Password for OpenBao user '${username}': "
IFS= read -r -s iac_password
printf "\n"

if [[ -z "${iac_password}" ]]; then
  echo "No password entered; aborting." >&2
  exit 1
fi

login_json="$(
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_LOGIN_USER=${username}" "BAO_LOGIN_PASSWORD=${iac_password}" \
    sh -lc 'bao login -method=userpass -format=json username="${BAO_LOGIN_USER}" password="${BAO_LOGIN_PASSWORD}"'
)"
unset iac_password

client_token="$(jq -r '.auth.client_token // empty' <<<"${login_json}")"

if [[ -z "${client_token}" ]]; then
  echo "OpenBao login failed or no token returned." >&2
  exit 1
fi

cloudflare_api_token="$(
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_TOKEN=${client_token}" \
    bao kv get -field=CLOUDFLARE_API_TOKEN apps/iac/cloudflare
)"

record_id="$(
  curl -fsS \
    -H "Authorization: Bearer ${cloudflare_api_token}" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${record_name}" |
    jq -r '.result[0].id // empty'
)"

unset cloudflare_api_token

if [[ -z "${record_id}" ]]; then
  echo "No Cloudflare DNS record found for ${record_name} in zone ${zone_id}." >&2
  exit 1
fi

if tofu -chdir="${repo_root}/terraform/cloudflare" state show "${resource_address}" >/dev/null 2>&1; then
  echo "${resource_address} is already in Terraform state."
else
  tofu -chdir="${repo_root}/terraform/cloudflare" import "${resource_address}" "${zone_id}/${record_id}"
fi
