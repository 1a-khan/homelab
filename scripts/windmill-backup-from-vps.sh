#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backup_dir="${repo_root}/backups/windmill"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
remote_dir="~/windmill-migration"
remote_host="${WINDMILL_VPS_HOST:-hetzner-prod}"
db_container="${WINDMILL_DB_CONTAINER:-db-ngck8kk48wcgoc44kos444w8}"
service_dir="${WINDMILL_COOLIFY_DIR:-/data/coolify/services/ngck8kk48wcgoc44kos444w8}"

mkdir -p "${backup_dir}"
chmod 700 "${backup_dir}"

ssh "${remote_host}" "set -euo pipefail
  mkdir -p ${remote_dir}
  sudo docker exec ${db_container} sh -lc 'pg_dump -Fc -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\"' > ${remote_dir}/windmill-db-${timestamp}.dump
  sudo cp ${service_dir}/docker-compose.yml ${remote_dir}/windmill-compose-${timestamp}.yml
  sudo awk -F= 'NF && \$1 !~ /^#/ {print \$1}' ${service_dir}/.env | sort > ${remote_dir}/windmill-env-keys-${timestamp}.txt
  cd ${remote_dir}
  sudo chown \"\$(id -u):\$(id -g)\" windmill-db-${timestamp}.dump windmill-compose-${timestamp}.yml windmill-env-keys-${timestamp}.txt
  sha256sum windmill-db-${timestamp}.dump windmill-compose-${timestamp}.yml windmill-env-keys-${timestamp}.txt > windmill-${timestamp}.sha256
  sudo chown \"\$(id -u):\$(id -g)\" windmill-${timestamp}.sha256"

scp "${remote_host}:windmill-migration/windmill-db-${timestamp}.dump" "${backup_dir}/"
scp "${remote_host}:windmill-migration/windmill-compose-${timestamp}.yml" "${backup_dir}/"
scp "${remote_host}:windmill-migration/windmill-env-keys-${timestamp}.txt" "${backup_dir}/"
scp "${remote_host}:windmill-migration/windmill-${timestamp}.sha256" "${backup_dir}/"

(
  cd "${backup_dir}"
  sha256sum -c "windmill-${timestamp}.sha256"
)

echo "Windmill backup saved in ${backup_dir}"
