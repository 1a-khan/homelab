#!/usr/bin/env bash
# Secrets for the Flowloom connector worker on k3s (kubernetes/apps/flowloom-connectors).
# Run it to see the guide: bash scripts/flowloom-connectors-bootstrap-k3s.sh [env ...] [--rotate-key]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/scripts/lib/script-guide.sh"

rotate=false
envs=()
for a in "$@"; do
  if [ "$a" = "--rotate-key" ]; then rotate=true; else envs+=("$a"); fi
done
[ "${#envs[@]}" -gt 0 ] || envs=(dev)

script_guide <<'GUIDE'
Flowloom connectors on k3s: the worker's two credentials
--------------------------------------------------------
Usage:  bash scripts/flowloom-connectors-bootstrap-k3s.sh [env ...] [--rotate-key]   (default: dev)

Per environment, into OpenBao apps/flowloom-connectors-<env> (External Secrets
gives them to the pod; nothing is printed):
  1. FLOWLOOM_API_KEY: a PLATFORM worker key of that engine, made inside the
     engine pod (Flowloom.Release.create_platform_key). Kept on re-runs;
     --rotate-key makes a new one (revoke the old one in Studio, API Keys).
  2. OPENBAO_ROLE_ID / OPENBAO_SECRET_ID: a fresh login for the AppRole
     flowloom-connectors-<env> (made by flowloom-connectors-approle-openbao.sh):
     reads connections, issues and rotates the Microsoft app secrets.

Then push the homelab repo; ArgoCD starts flowloom-connectors-<env>.
It asks for your OpenBao admin login.
GUIDE

kubeconfig="${repo_root}/kubeconfig"
k() { kubectl --kubeconfig "${kubeconfig}" "$@"; }

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin
bao() { k -n openbao exec -i openbao-0 -- env "BAO_TOKEN=${BAO_TOKEN}" "$@"; }

for env_slug in "${envs[@]}"; do
  [[ "${env_slug}" =~ ^[a-z0-9]+$ ]] || { echo "invalid environment: ${env_slug}" >&2; exit 1; }
  path="apps/flowloom-connectors-${env_slug}"
  role="flowloom-connectors-${env_slug}"

  bao bao read "auth/approle/role/${role}" >/dev/null 2>&1 || {
    echo "[${env_slug}] AppRole ${role} missing: run scripts/flowloom-connectors-approle-openbao.sh ${env_slug} first." >&2
    exit 1
  }

  # 1. platform worker key (inside the engine pod; only its hint is printed)
  api_key=""
  if [ "${rotate}" = false ]; then
    api_key="$(bao bao kv get -field=FLOWLOOM_API_KEY "${path}" 2>/dev/null || true)"
  fi
  if [ -z "${api_key}" ]; then
    pod="$(k -n "flowloom-${env_slug}" get pods -l app.kubernetes.io/name=flowloom \
      --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
    k -n "flowloom-${env_slug}" exec "${pod}" -c flowloom -- \
      /app/bin/flowloom eval 'Flowloom.Release.create_platform_key("flowloom-connectors", "/tmp")' | tail -1
    api_key="$(k -n "flowloom-${env_slug}" exec "${pod}" -c flowloom -- sh -c \
      'f=/tmp/.flowloom-platform-worker-flowloom-connectors.env; sed -n "s/^FLOWLOOM_API_KEY=//p" "$f"; rm -f "$f"')"
    [ -n "${api_key}" ] || { echo "[${env_slug}] could not create the platform key" >&2; exit 1; }
    echo "[${env_slug}] new platform worker key created."
  else
    echo "[${env_slug}] platform worker key exists (kept; --rotate-key replaces it)."
  fi

  # 2. a fresh AppRole login for the pod
  role_id="$(bao bao read -field=role_id "auth/approle/role/${role}/role-id")"
  secret_id="$(bao bao write -f -field=secret_id "auth/approle/role/${role}/secret-id")"

  # 3. store (JSON over stdin: values never become arguments)
  jq -n --arg k "${api_key}" --arg r "${role_id}" --arg s "${secret_id}" \
    '{FLOWLOOM_API_KEY: $k, OPENBAO_ROLE_ID: $r, OPENBAO_SECRET_ID: $s}' \
    | bao bao kv put "${path}" - >/dev/null
  unset api_key role_id secret_id
  echo "[${env_slug}] stored in ${path}."
done

echo "Next: commit + push the homelab repo; ArgoCD starts the connector."
