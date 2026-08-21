#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

if kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" bao kv get -field=API_KEY apps/calendar-agent/api >/dev/null 2>&1; then
  echo "Calendar Agent API key already exists in OpenBao at apps/calendar-agent/api."
  exit 0
fi

api_key="$(openssl rand -hex 32)"

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" "API_KEY=${api_key}" \
  sh -lc 'bao kv put apps/calendar-agent/api API_KEY="${API_KEY}" >/dev/null'

unset api_key

echo "Calendar Agent API key stored in OpenBao at apps/calendar-agent/api."
