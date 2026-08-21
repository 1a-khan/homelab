#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backup_dir="${repo_root}/backups/n8n"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
remote_dir="~/n8n-migration"

mkdir -p "${backup_dir}"
chmod 700 "${backup_dir}"

ssh hetzner-prod "set -euo pipefail
  mkdir -p ${remote_dir}
  sudo docker exec postgresql-m40w04kco0ww0wk0c4wc4w04 sh -lc 'pg_dump -Fc -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\"' > ${remote_dir}/n8n-db-${timestamp}.dump
  sudo tar -C /var/lib/docker/volumes/m40w04kco0ww0wk0c4wc4w04_n8n-data/_data -czf ${remote_dir}/n8n-data-${timestamp}.tgz .
  cd ${remote_dir}
  sha256sum n8n-db-${timestamp}.dump n8n-data-${timestamp}.tgz > n8n-${timestamp}.sha256
  sudo chown \"\$(id -u):\$(id -g)\" n8n-db-${timestamp}.dump n8n-data-${timestamp}.tgz n8n-${timestamp}.sha256"

scp "hetzner-prod:n8n-migration/n8n-db-${timestamp}.dump" "${backup_dir}/"
scp "hetzner-prod:n8n-migration/n8n-data-${timestamp}.tgz" "${backup_dir}/"
scp "hetzner-prod:n8n-migration/n8n-${timestamp}.sha256" "${backup_dir}/"

(
  cd "${backup_dir}"
  sha256sum -c "n8n-${timestamp}.sha256"
)

echo "n8n backup saved in ${backup_dir}"
