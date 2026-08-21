#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
eso_namespace="external-secrets"
eso_service_account="external-secrets"
policy_name="kubernetes-app-secrets"
role_name="external-secrets"
mount_path="kubernetes"

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

kubernetes_host="https://kubernetes.default.svc:443"
kubernetes_ca_cert="$(
  kubectl --kubeconfig "${kubeconfig}" -n "${eso_namespace}" get configmap kube-root-ca.crt \
    -o jsonpath='{.data.ca\.crt}'
)"
token_reviewer_jwt="$(
  kubectl --kubeconfig "${kubeconfig}" -n "${eso_namespace}" create token "${eso_service_account}" \
    --duration=8760h
)"

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" bao auth enable -path="${mount_path}" kubernetes >/dev/null 2>&1 || true

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" \
      "KUBERNETES_HOST=${kubernetes_host}" \
      "KUBERNETES_CA_CERT=${kubernetes_ca_cert}" \
      "TOKEN_REVIEWER_JWT=${token_reviewer_jwt}" \
      "MOUNT_PATH=${mount_path}" \
  sh -lc 'bao write "auth/${MOUNT_PATH}/config" \
    token_reviewer_jwt="${TOKEN_REVIEWER_JWT}" \
    kubernetes_host="${KUBERNETES_HOST}" \
    kubernetes_ca_cert="${KUBERNETES_CA_CERT}"'

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" "POLICY_NAME=${policy_name}" \
  sh -lc 'bao policy write "${POLICY_NAME}" -' <<'POLICY'
path "apps/data/*" {
  capabilities = ["read"]
}

path "apps/metadata/*" {
  capabilities = ["read", "list"]
}

path "azure/creds/*" {
  capabilities = ["read"]
}
POLICY

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" bao write "auth/${mount_path}/role/${role_name}" \
    bound_service_account_names="${eso_service_account}" \
    bound_service_account_namespaces="${eso_namespace}" \
    policies="${policy_name}" \
    ttl="1h"

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" bao secrets enable -path=apps kv-v2 >/dev/null 2>&1 || true

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" bao kv put apps/demo/app \
    username="demo-user" \
    password="demo-password-from-openbao"

echo "OpenBao Kubernetes auth configured."
echo "Policy: ${policy_name}"
echo "Role: ${role_name}"
echo "Demo secret: apps/demo/app"
