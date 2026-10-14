#!/usr/bin/env bash
# Step 1 of the Keycloak setup (before ArgoCD deploys it), see the Flowloom
# repo's docs/IAM.md:
#   - generates Keycloak's secrets into OpenBao apps/keycloak (ExternalSecret
#     "keycloak" maps them into the pod): the temporary master-realm admin and
#     the database login. Existing values are kept, so re-running is safe.
#   - creates the "keycloak" role and database in the shared Postgres
#     (namespace database), or resets the role's password to the stored one.
# No secret is printed. Usage: bash scripts/keycloak-bootstrap-openbao.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
kv_path="apps/keycloak"
db_name="keycloak"
db_user="keycloak"

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

bao() {
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- env "BAO_TOKEN=${BAO_TOKEN}" "$@"
}

if bao bao kv get -field=KC_DB_PASSWORD "${kv_path}" >/dev/null 2>&1; then
  echo "Keycloak secrets already exist at ${kv_path}; keeping them."
else
  admin_password="$(openssl rand -base64 33 | tr -d '/+=' | cut -c1-32)"
  db_password="$(openssl rand -hex 32)"
  bao "KC_ADMIN_PW=${admin_password}" "KC_DB_PW=${db_password}" "DB_USER=${db_user}" "KV_PATH=${kv_path}" \
    sh -lc 'bao kv put "${KV_PATH}" \
      KC_BOOTSTRAP_ADMIN_USERNAME=kc-bootstrap-admin \
      KC_BOOTSTRAP_ADMIN_PASSWORD="${KC_ADMIN_PW}" \
      KC_DB_USERNAME="${DB_USER}" \
      KC_DB_PASSWORD="${KC_DB_PW}"' >/dev/null
  unset admin_password db_password
  echo "Generated Keycloak secrets into ${kv_path}."
fi

# The DB role must match what Keycloak will log in with: read it back (never printed).
db_password="$(bao bao kv get -field=KC_DB_PASSWORD "${kv_path}")"

kubectl --kubeconfig "${kubeconfig}" -n database rollout status statefulset/postgres --timeout=180s >/dev/null
postgres_pod="$(kubectl --kubeconfig "${kubeconfig}" -n database get pod -l app.kubernetes.io/name=postgres -o jsonpath='{.items[0].metadata.name}')"

kubectl --kubeconfig "${kubeconfig}" -n database exec -i "${postgres_pod}" -- \
  env "APP_DB_USER=${db_user}" "APP_DB_PASSWORD=${db_password}" "APP_DB_NAME=${db_name}" sh -lc '
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
unset db_password

cat <<NEXT
Postgres: role "${db_user}" and database "${db_name}" are ready.

Next:
  1. Apply terraform/cloudflare (tunnel route + DNS for auth.miak-it.com):
       bash scripts/iac-tofu-cloudflare.sh plan   # then apply
  2. Commit + push the homelab repo; ArgoCD syncs the "keycloak" app.
     Watch it come up:
       kubectl --kubeconfig kubeconfig -n keycloak get pods -w
  3. Check: https://auth.miak-it.com/realms/flowloom/.well-known/openid-configuration
  4. Run: bash scripts/keycloak-bootstrap-flowloom.sh
NEXT
