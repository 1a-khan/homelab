#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
backup_dir="${repo_root}/backups/n8n"
db_dump="${1:-$(ls -t "${backup_dir}"/n8n-db-*.dump 2>/dev/null | head -n 1 || true)}"
data_tgz="${2:-$(ls -t "${backup_dir}"/n8n-data-*.tgz 2>/dev/null | head -n 1 || true)}"

if [[ -z "${db_dump}" || ! -f "${db_dump}" ]]; then
  echo "Missing n8n database dump." >&2
  exit 1
fi

if [[ -z "${data_tgz}" || ! -f "${data_tgz}" ]]; then
  echo "Missing n8n data archive." >&2
  exit 1
fi

kubectl --kubeconfig "${kubeconfig}" -n n8n scale deployment n8n n8n-worker n8n-task-runners --replicas=0 || true
kubectl --kubeconfig "${kubeconfig}" -n database rollout status statefulset/postgres --timeout=180s

postgres_pod="$(kubectl --kubeconfig "${kubeconfig}" -n database get pod -l app.kubernetes.io/name=postgres -o jsonpath='{.items[0].metadata.name}')"
app_db_user="$(kubectl --kubeconfig "${kubeconfig}" -n n8n get secret n8n -o jsonpath='{.data.SERVICE_USER_POSTGRES}' | base64 -d)"
app_db_password="$(kubectl --kubeconfig "${kubeconfig}" -n n8n get secret n8n -o jsonpath='{.data.SERVICE_PASSWORD_POSTGRES}' | base64 -d)"

kubectl --kubeconfig "${kubeconfig}" -n database cp "${db_dump}" "${postgres_pod}:/tmp/n8n.dump"
kubectl --kubeconfig "${kubeconfig}" -n database exec "${postgres_pod}" -- \
  env "APP_DB_USER=${app_db_user}" "APP_DB_PASSWORD=${app_db_password}" sh -lc "
  set -eu
  psql -U postgres -v ON_ERROR_STOP=1 \
    -v app_user=\"\${APP_DB_USER}\" \
    -v app_password=\"\${APP_DB_PASSWORD}\" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app_user') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'app_user', :'app_password') \gexec
SQL
  dropdb -U postgres --if-exists n8n
  createdb -U postgres -O \"\${APP_DB_USER}\" n8n
  pg_restore -U postgres -d n8n --clean --if-exists /tmp/n8n.dump
  rm -f /tmp/n8n.dump
"

kubectl --kubeconfig "${kubeconfig}" -n n8n scale deployment n8n --replicas=1
kubectl --kubeconfig "${kubeconfig}" -n n8n rollout status deployment/n8n --timeout=300s
n8n_pod="$(kubectl --kubeconfig "${kubeconfig}" -n n8n get pod -l app.kubernetes.io/name=n8n,app.kubernetes.io/component=server -o jsonpath='{.items[0].metadata.name}')"
kubectl --kubeconfig "${kubeconfig}" -n n8n cp "${data_tgz}" "${n8n_pod}:/tmp/n8n-data.tgz"
kubectl --kubeconfig "${kubeconfig}" -n n8n exec "${n8n_pod}" -- sh -lc '
  set -eu
  tar -xzf /tmp/n8n-data.tgz -C /home/node/.n8n
  rm -f /tmp/n8n-data.tgz
'

kubectl --kubeconfig "${kubeconfig}" -n n8n rollout restart deployment/n8n
kubectl --kubeconfig "${kubeconfig}" -n n8n scale deployment n8n-worker n8n-task-runners --replicas=1
kubectl --kubeconfig "${kubeconfig}" -n n8n rollout status deployment/n8n --timeout=300s
kubectl --kubeconfig "${kubeconfig}" -n n8n rollout status deployment/n8n-worker --timeout=300s
kubectl --kubeconfig "${kubeconfig}" -n n8n rollout status deployment/n8n-task-runners --timeout=300s

kubectl --kubeconfig "${kubeconfig}" -n n8n get pods
