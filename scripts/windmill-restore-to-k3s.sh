#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
backup_dir="${repo_root}/backups/windmill"
db_dump="${1:-$(ls -t "${backup_dir}"/windmill-db-*.dump 2>/dev/null | head -n 1 || true)}"
target_db="${WINDMILL_TARGET_DB:-windmill}"

if [[ -z "${db_dump}" || ! -f "${db_dump}" ]]; then
  echo "Missing Windmill database dump." >&2
  exit 1
fi

kubectl --kubeconfig "${kubeconfig}" -n windmill scale deployment windmill-server windmill-worker-default windmill-worker-native windmill-lsp --replicas=0 || true
kubectl --kubeconfig "${kubeconfig}" -n database rollout status statefulset/postgres --timeout=180s

postgres_pod="$(kubectl --kubeconfig "${kubeconfig}" -n database get pod -l app.kubernetes.io/name=postgres -o jsonpath='{.items[0].metadata.name}')"
app_db_user="$(kubectl --kubeconfig "${kubeconfig}" -n windmill get secret windmill -o jsonpath='{.data.SERVICE_USER_POSTGRES}' | base64 -d)"
app_db_password="$(kubectl --kubeconfig "${kubeconfig}" -n windmill get secret windmill -o jsonpath='{.data.SERVICE_PASSWORD_POSTGRES}' | base64 -d)"

kubectl --kubeconfig "${kubeconfig}" -n database cp "${db_dump}" "${postgres_pod}:/tmp/windmill.dump"
kubectl --kubeconfig "${kubeconfig}" -n database exec "${postgres_pod}" -- \
  env "APP_DB_USER=${app_db_user}" "APP_DB_PASSWORD=${app_db_password}" "TARGET_DB=${target_db}" sh -lc "
  set -eu
  psql -U postgres -v ON_ERROR_STOP=1 \
    -v app_user=\"\${APP_DB_USER}\" \
    -v app_password=\"\${APP_DB_PASSWORD}\" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app_user') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'app_user', :'app_password') \gexec
SELECT 'CREATE ROLE windmill_user NOLOGIN'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'windmill_user') \gexec
SELECT 'CREATE ROLE windmill_admin NOLOGIN'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'windmill_admin') \gexec
SELECT format('GRANT windmill_user TO %I', :'app_user') \gexec
SELECT format('GRANT windmill_admin TO %I', :'app_user') \gexec
SQL
  dropdb -U postgres --if-exists \"\${TARGET_DB}\"
  createdb -U postgres -O \"\${APP_DB_USER}\" \"\${TARGET_DB}\"
  pg_restore -U postgres -d \"\${TARGET_DB}\" --clean --if-exists --no-owner --no-acl /tmp/windmill.dump
  psql -U postgres -d \"\${TARGET_DB}\" -v ON_ERROR_STOP=1 -c \"ALTER SCHEMA public OWNER TO \\\"\${APP_DB_USER}\\\";\"
  psql -U postgres -d \"\${TARGET_DB}\" -v ON_ERROR_STOP=1 -c \"GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \\\"\${APP_DB_USER}\\\";\"
  psql -U postgres -d \"\${TARGET_DB}\" -v ON_ERROR_STOP=1 -c \"GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \\\"\${APP_DB_USER}\\\";\"
  psql -U postgres -d \"\${TARGET_DB}\" -v ON_ERROR_STOP=1 -c \"GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO \\\"\${APP_DB_USER}\\\";\"
  rm -f /tmp/windmill.dump
"

kubectl --kubeconfig "${kubeconfig}" -n windmill scale deployment windmill-server windmill-worker-default windmill-worker-native windmill-lsp --replicas=1
kubectl --kubeconfig "${kubeconfig}" -n windmill rollout status deployment/windmill-server --timeout=300s
kubectl --kubeconfig "${kubeconfig}" -n windmill rollout status deployment/windmill-worker-default --timeout=300s
kubectl --kubeconfig "${kubeconfig}" -n windmill rollout status deployment/windmill-worker-native --timeout=300s
kubectl --kubeconfig "${kubeconfig}" -n windmill rollout status deployment/windmill-lsp --timeout=300s
kubectl --kubeconfig "${kubeconfig}" -n windmill get pods
