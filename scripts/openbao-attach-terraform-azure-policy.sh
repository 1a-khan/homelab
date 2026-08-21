#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
policy_name="terraform-azure"

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

terraform_user_json="$(
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_TOKEN=${BAO_TOKEN}" \
    bao read -format=json auth/userpass/users/terraform
)"

existing_policies="$(
  jq -er '(.data.token_policies // .data.policies // []) | join(",")' <<<"${terraform_user_json}"
)"

if [[ ",${existing_policies}," == *",${policy_name},"* ]]; then
  echo "OpenBao user 'terraform' already has policy '${policy_name}'."
  exit 0
fi

if [[ -n "${existing_policies}" ]]; then
  terraform_policies="${existing_policies},${policy_name}"
else
  terraform_policies="${policy_name}"
fi

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" "TERRAFORM_POLICIES=${terraform_policies}" \
  sh -lc 'bao write auth/userpass/users/terraform policies="${TERRAFORM_POLICIES}" >/dev/null'

echo "Attached policy '${policy_name}' to OpenBao user 'terraform'."
