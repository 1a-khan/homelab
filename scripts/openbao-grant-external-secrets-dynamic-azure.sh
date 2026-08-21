#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
policy_name="kubernetes-app-secrets"

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

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

graph_namespaces="$(
  {
    printf '%s\n' external-secrets
    kubectl --kubeconfig "${kubeconfig}" get namespaces \
      -l 'miak-it.com/graph-mail-mover=true' \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
    kubectl --kubeconfig "${kubeconfig}" get namespaces \
      -l 'miak-it.com/graph-onedrive-manager=true' \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
    kubectl --kubeconfig "${kubeconfig}" get namespaces \
      -l 'miak-it.com/graph-calendar-agent=true' \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  } | sed '/^$/d' | sort -u | paste -sd, -
)"

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" \
      "GRAPH_NAMESPACES=${graph_namespaces}" \
      "POLICY_NAME=${policy_name}" \
  sh -lc 'bao write auth/kubernetes/role/external-secrets \
    bound_service_account_names="external-secrets" \
    bound_service_account_namespaces="${GRAPH_NAMESPACES}" \
    policies="${POLICY_NAME}" \
    ttl="1h" >/dev/null'

echo "Policy '${policy_name}' now allows External Secrets Operator to read OpenBao Azure dynamic credentials."
echo "Kubernetes auth role external-secrets accepts service account external-secrets from: ${graph_namespaces}"
