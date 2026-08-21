#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
mount_path="azure"
role_name="terraform"
policy_name="terraform-azure"

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

printf "Azure subscription ID: "
IFS= read -r subscription_id
printf "Azure tenant ID: "
IFS= read -r tenant_id
printf "Azure bootstrap app client ID: "
IFS= read -r client_id
printf "Azure bootstrap app client secret: "
IFS= read -r -s client_secret
printf "\n"
printf "Azure role assigned to generated Terraform credentials [Contributor]: "
IFS= read -r azure_role_name
azure_role_name="${azure_role_name:-Contributor}"
printf "Azure scope for generated Terraform credentials [/subscriptions/%s]: " "${subscription_id}"
IFS= read -r azure_scope
azure_scope="${azure_scope:-/subscriptions/${subscription_id}}"
printf "Existing Terraform app registration Object ID, blank to create dynamic apps each lease: "
IFS= read -r application_object_id
printf "Generated credential TTL [1h]: "
IFS= read -r ttl
ttl="${ttl:-1h}"
printf "Generated credential max TTL [4h]: "
IFS= read -r max_ttl
max_ttl="${max_ttl:-4h}"

if [[ -z "${subscription_id}" || -z "${tenant_id}" || -z "${client_id}" || -z "${client_secret}" ]]; then
  echo "Azure subscription ID, tenant ID, client ID, and client secret are required." >&2
  exit 1
fi

azure_roles_json="$(jq -cn \
  --arg role_name "${azure_role_name}" \
  --arg scope "${azure_scope}" \
  '[{role_name: $role_name, scope: $scope}]')"

if ! kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" \
  bao secrets enable -path="${mount_path}" -plugin-name=azure plugin >/dev/null; then
  if kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_TOKEN=${BAO_TOKEN}" \
    bao secrets list -format=json | jq -e --arg mount "${mount_path}/" 'has($mount)' >/dev/null; then
    echo "Azure secrets engine already enabled at '${mount_path}/'."
  else
    echo "Failed to enable Azure secrets engine." >&2
    echo "If the error says the plugin is not in the catalog, delete/recreate the OpenBao pod and unseal it so plugin auto-registration can run." >&2
    exit 1
  fi
fi

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" \
      "AZURE_SUBSCRIPTION_ID=${subscription_id}" \
      "AZURE_TENANT_ID=${tenant_id}" \
      "AZURE_CLIENT_ID=${client_id}" \
      "AZURE_CLIENT_SECRET=${client_secret}" \
  sh -lc 'bao write azure/config \
    subscription_id="${AZURE_SUBSCRIPTION_ID}" \
    tenant_id="${AZURE_TENANT_ID}" \
    client_id="${AZURE_CLIENT_ID}" \
    client_secret="${AZURE_CLIENT_SECRET}" >/dev/null'

if [[ -n "${application_object_id}" ]]; then
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_TOKEN=${BAO_TOKEN}" \
        "APPLICATION_OBJECT_ID=${application_object_id}" \
        "ROLE_NAME=${role_name}" \
        "TTL=${ttl}" \
        "MAX_TTL=${max_ttl}" \
    sh -lc 'bao write "azure/roles/${ROLE_NAME}" \
      ttl="${TTL}" \
      max_ttl="${MAX_TTL}" \
      application_object_id="${APPLICATION_OBJECT_ID}" >/dev/null'
else
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_TOKEN=${BAO_TOKEN}" \
        "AZURE_ROLES_JSON=${azure_roles_json}" \
        "ROLE_NAME=${role_name}" \
        "TTL=${ttl}" \
        "MAX_TTL=${max_ttl}" \
    sh -lc 'bao write "azure/roles/${ROLE_NAME}" \
      ttl="${TTL}" \
      max_ttl="${MAX_TTL}" \
      azure_roles="${AZURE_ROLES_JSON}" >/dev/null'
fi

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" \
      "AZURE_SUBSCRIPTION_ID=${subscription_id}" \
      "AZURE_TENANT_ID=${tenant_id}" \
      "AZURE_ROLE_NAME=${role_name}" \
      "APPLICATION_OBJECT_ID=${application_object_id}" \
  sh -lc 'bao kv put apps/iac/azure \
    subscription_id="${AZURE_SUBSCRIPTION_ID}" \
    tenant_id="${AZURE_TENANT_ID}" \
    role_name="${AZURE_ROLE_NAME}" \
    application_object_id="${APPLICATION_OBJECT_ID}" >/dev/null'

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" "POLICY_NAME=${policy_name}" \
  sh -lc 'bao policy write "${POLICY_NAME}" -' <<'POLICY'
path "azure/creds/terraform" {
  capabilities = ["read"]
}

path "azure/roles/terraform" {
  capabilities = ["read"]
}

path "apps/data/iac/azure" {
  capabilities = ["read"]
}

path "apps/metadata/iac/azure" {
  capabilities = ["read"]
}
POLICY

terraform_user_json="$(
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_TOKEN=${BAO_TOKEN}" \
    bao read -format=json auth/userpass/users/terraform 2>/dev/null || true
)"
if [[ -z "${terraform_user_json}" ]]; then
  echo "Could not read OpenBao user 'terraform'. Create it first, then rerun this script." >&2
  exit 1
fi

if ! existing_policies="$(
  jq -er '(.data.token_policies // .data.policies // []) | join(",")' <<<"${terraform_user_json}"
)"; then
  echo "Could not parse OpenBao user 'terraform' policy data." >&2
  echo "Azure secrets engine and policy were configured, but the policy was not attached to the terraform user." >&2
  echo "Run this manually after checking the user's current policies:" >&2
  echo "  bao write auth/userpass/users/terraform policies='${policy_name}'" >&2
  exit 1
fi

if [[ ",${existing_policies}," != *",${policy_name},"* ]]; then
  if [[ -n "${existing_policies}" ]]; then
    terraform_policies="${existing_policies},${policy_name}"
  else
    terraform_policies="${policy_name}"
  fi
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_TOKEN=${BAO_TOKEN}" "TERRAFORM_POLICIES=${terraform_policies}" \
    sh -lc 'bao write auth/userpass/users/terraform policies="${TERRAFORM_POLICIES}" >/dev/null'
fi

unset client_secret

echo "Azure secrets engine is configured at '${mount_path}/'."
echo "Terraform can read dynamic credentials from 'azure/creds/${role_name}'."
echo "OpenBao user 'terraform' has policy '${policy_name}'."
