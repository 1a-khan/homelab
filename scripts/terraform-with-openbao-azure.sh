#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"

if [[ "$#" -eq 0 ]]; then
  echo "Usage: scripts/terraform-with-openbao-azure.sh <terraform/tofu command>" >&2
  echo "Example: scripts/terraform-with-openbao-azure.sh tofu -chdir=terraform/azure plan" >&2
  exit 1
fi

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_userpass terraform
trap openbao_revoke_login_token EXIT

azure_meta="$(
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_TOKEN=${BAO_TOKEN}" bao kv get -format=json apps/iac/azure
)"

role_name="$(jq -r '.data.data.role_name // "terraform"' <<<"${azure_meta}")"
export ARM_SUBSCRIPTION_ID="$(jq -r '.data.data.subscription_id' <<<"${azure_meta}")"
export ARM_TENANT_ID="$(jq -r '.data.data.tenant_id' <<<"${azure_meta}")"

azure_creds=""
for attempt in 1 2 3 4 5 6; do
  set +e
  azure_creds="$(
    kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
      env "BAO_TOKEN=${BAO_TOKEN}" bao read -format=json "azure/creds/${role_name}"
  )"
  status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    break
  fi

  if [[ "${attempt}" -eq 6 ]]; then
    echo "Failed to retrieve Azure credentials from OpenBao after ${attempt} attempts." >&2
    exit "${status}"
  fi

  sleep_seconds=$((attempt * 20))
  echo "Azure credential creation failed on attempt ${attempt}; retrying in ${sleep_seconds}s..." >&2
  sleep "${sleep_seconds}"
done

export ARM_CLIENT_ID="$(jq -r '.data.client_id' <<<"${azure_creds}")"
export ARM_CLIENT_SECRET="$(jq -r '.data.client_secret' <<<"${azure_creds}")"

if [[ -z "${ARM_SUBSCRIPTION_ID}" || -z "${ARM_TENANT_ID}" || -z "${ARM_CLIENT_ID}" || -z "${ARM_CLIENT_SECRET}" ]]; then
  echo "Failed to retrieve complete Azure credentials from OpenBao." >&2
  exit 1
fi

"$@"
