#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

if kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" bao kv get -field=POSTGRES_PASSWORD apps/platform/postgres >/dev/null 2>&1; then
  echo "apps/platform/postgres already exists; leaving password unchanged."
else
  postgres_password="$(openssl rand -base64 36)"
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_TOKEN=${BAO_TOKEN}" \
    bao kv put apps/platform/postgres "POSTGRES_PASSWORD=${postgres_password}" >/dev/null
  echo "Created apps/platform/postgres."
  unset postgres_password
fi

if kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" bao kv get -field=VALKEY_PASSWORD apps/platform/valkey >/dev/null 2>&1; then
  echo "apps/platform/valkey already exists; leaving password unchanged."
else
  valkey_password="$(openssl rand -base64 36)"
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_TOKEN=${BAO_TOKEN}" \
    bao kv put apps/platform/valkey "VALKEY_PASSWORD=${valkey_password}" >/dev/null
  echo "Created apps/platform/valkey."
  unset valkey_password
fi

echo "Platform secrets are ready in OpenBao."
