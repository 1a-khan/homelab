#!/usr/bin/env bash
# Prepares OpenBao and Postgres for the Flowloom engines on k3s.
# Run it to see the guide: bash scripts/flowloom-k3s-bootstrap-openbao.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/scripts/lib/script-guide.sh"

rotate_ghcr=false
envs=()
for a in "$@"; do
  if [ "$a" = "--rotate-ghcr" ]; then rotate_ghcr=true; else envs+=("$a"); fi
done
[ "${#envs[@]}" -gt 0 ] || envs=(dev staging prod)

script_guide <<'GUIDE'
Flowloom on k3s: databases, engine secrets and image pull token
---------------------------------------------------------------
Usage:  bash scripts/flowloom-k3s-bootstrap-openbao.sh [env ...] [--rotate-ghcr]
        (default envs: dev staging prod; safe to re-run, existing values are kept)

For each environment (OpenBao apps/flowloom-<env>, written with kv patch so the
AppRole and Keycloak values already there stay):
  1. Postgres role + database flowloom_<env> on the shared Postgres, and
     DATABASE_URL (+ FLOWLOOM_DB_PASSWORD) pointing at it.
  2. SECRET_KEY_BASE: generated once and then kept. It must never change for
     an environment: webhook URLs and stored webhook secrets derive from it.
  3. A check that everything the engine needs is there; missing values are
     listed with the script that provides them.

Once: GHCR_USERNAME / GHCR_TOKEN in apps/ghcr so the cluster can pull the
private image ghcr.io/1a-khan/flowloom. Create the token at GitHub ->
Settings -> Developer settings -> Personal access tokens (classic), scope
read:packages only. You'll paste it hidden; --rotate-ghcr replaces it.

It will ask for: your OpenBao admin login, and the GitHub token (first run).
Nothing secret is printed.
GUIDE

kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

bao() {
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- env "BAO_TOKEN=${BAO_TOKEN}" "$@"
}
bao_has() { bao bao kv get -field="$2" "$1" >/dev/null 2>&1; }
bao_patch() {
  # bao_patch <path> KEY=VALUE...: patch (keeps other keys), put if the path is new.
  local path="$1"; shift
  local env_args=() i=0
  for kv in "$@"; do env_args+=("P${i}=${kv}"); i=$((i + 1)); done
  bao "KV_PATH=${path}" "N=${i}" "${env_args[@]}" sh -lc '
    i=0; set --
    while [ "$i" -lt "$N" ]; do eval "set -- \"\$@\" \"\${P$i}\""; i=$((i + 1)); done
    bao kv patch "$KV_PATH" "$@" >/dev/null 2>&1 || bao kv put "$KV_PATH" "$@" >/dev/null'
}

kubectl --kubeconfig "${kubeconfig}" -n database rollout status statefulset/postgres --timeout=180s >/dev/null
postgres_pod="$(kubectl --kubeconfig "${kubeconfig}" -n database get pod -l app.kubernetes.io/name=postgres -o jsonpath='{.items[0].metadata.name}')"

for env_slug in "${envs[@]}"; do
  [[ "${env_slug}" =~ ^[a-z0-9]+$ ]] || { echo "invalid environment: ${env_slug}" >&2; exit 1; }
  kv_path="apps/flowloom-${env_slug}"
  db="flowloom_${env_slug}"

  # -- 1. database --------------------------------------------------------------
  if bao_has "${kv_path}" FLOWLOOM_DB_PASSWORD; then
    db_password="$(bao bao kv get -field=FLOWLOOM_DB_PASSWORD "${kv_path}")"
  else
    db_password="$(openssl rand -hex 32)"
  fi

  kubectl --kubeconfig "${kubeconfig}" -n database exec -i "${postgres_pod}" -- \
    env "APP_DB_USER=${db}" "APP_DB_PASSWORD=${db_password}" "APP_DB_NAME=${db}" sh -lc '
    set -eu
    psql -U postgres -v ON_ERROR_STOP=1 -q \
      -v app_user="${APP_DB_USER}" -v app_password="${APP_DB_PASSWORD}" -v app_db="${APP_DB_NAME}" <<'"'"'SQL'"'"'
SELECT format('"'"'CREATE ROLE %I LOGIN PASSWORD %L'"'"', :'"'"'app_user'"'"', :'"'"'app_password'"'"')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'"'"'app_user'"'"') \gexec
SELECT format('"'"'ALTER ROLE %I WITH LOGIN PASSWORD %L'"'"', :'"'"'app_user'"'"', :'"'"'app_password'"'"') \gexec
SELECT format('"'"'CREATE DATABASE %I OWNER %I'"'"', :'"'"'app_db'"'"', :'"'"'app_user'"'"')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'"'"'app_db'"'"') \gexec
SQL
'
  url="ecto://${db}:${db_password}@postgres.database.svc.cluster.local:5432/${db}"
  bao_patch "${kv_path}" "FLOWLOOM_DB_PASSWORD=${db_password}" "DATABASE_URL=${url}"
  unset db_password url
  echo "[${env_slug}] database ${db} ready, DATABASE_URL stored."

  # -- 2. secret key base -------------------------------------------------------
  if bao_has "${kv_path}" SECRET_KEY_BASE; then
    echo "[${env_slug}] SECRET_KEY_BASE exists (kept: webhook URLs depend on it)."
  else
    skb="$(openssl rand -base64 48 | tr -d '\n')"
    bao_patch "${kv_path}" "SECRET_KEY_BASE=${skb}"
    unset skb
    echo "[${env_slug}] SECRET_KEY_BASE generated."
  fi

  # -- 3. completeness ----------------------------------------------------------
  missing=()
  for key in DATABASE_URL SECRET_KEY_BASE KEYCLOAK_CLIENT_SECRET KEYCLOAK_ADMIN_CLIENT_SECRET \
             OPENBAO_ADMIN_ROLE_NAME OPENBAO_ADMIN_ROLE_ID OPENBAO_ADMIN_SECRET_ID; do
    bao_has "${kv_path}" "${key}" || missing+=("${key}")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    echo "[${env_slug}] all engine secrets present."
  else
    echo "[${env_slug}] MISSING: ${missing[*]}" >&2
    echo "    KEYCLOAK_CLIENT_SECRET: keycloak-bootstrap-flowloom.sh; KEYCLOAK_ADMIN_CLIENT_SECRET:" >&2
    echo "    keycloak-flowloom-admin-setup.sh; OPENBAO_ADMIN_*: flowloom-bootstrap-env-approles-openbao.sh" >&2
  fi
done

# -- image pull token -------------------------------------------------------------
if [ "${rotate_ghcr}" = true ] || ! bao_has apps/ghcr GHCR_TOKEN; then
  printf 'GitHub token with read:packages (hidden): '
  IFS= read -r -s ghcr_token; printf '\n'
  [ -n "${ghcr_token}" ] || { echo "no token entered" >&2; exit 1; }
  bao_patch apps/ghcr "GHCR_USERNAME=1a-khan" "GHCR_TOKEN=${ghcr_token}"
  unset ghcr_token
  echo "Stored the image pull token in apps/ghcr."
else
  echo "Image pull token exists in apps/ghcr (use --rotate-ghcr to replace it)."
fi

cat <<NEXT

Next:
  1. Apply terraform/cloudflare (dev-flowloom / staging-flowloom / flowloom.miak-it.com):
       bash scripts/iac-tofu-cloudflare.sh plan   # then apply
  2. Commit + push the homelab repo; ArgoCD syncs flowloom-dev, -staging, -prod.
  3. Watch: kubectl --kubeconfig kubeconfig -n flowloom-dev get pods -w
NEXT
