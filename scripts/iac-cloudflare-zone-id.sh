#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
username="iac"
zone_name="${1:-}"

if [[ -z "${zone_name}" ]]; then
  echo "Usage: scripts/iac-cloudflare-zone-id.sh <zone-name>" >&2
  echo "Example: scripts/iac-cloudflare-zone-id.sh miak-it.de" >&2
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

printf "Password for OpenBao user '%s': " "${username}"
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

curl -fsS \
  -H "Authorization: Bearer ${cloudflare_api_token}" \
  "https://api.cloudflare.com/client/v4/zones?name=${zone_name}" |
  jq -r '.result[] | "\(.name)\t\(.id)\t\(.status)"'

unset cloudflare_api_token
