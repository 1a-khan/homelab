#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container_name="openbao-boyl1uvbqpc717bjozsutamd-133124215218"
remote_host="hetzner-prod"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
snapshot_name="openbao-raft-${timestamp}.snap"
remote_dir="~/openbao-migration"
local_dir="${repo_root}/backups/openbao"

mkdir -p "${local_dir}"

printf "OpenBao admin/root token for the current VPS instance: "
IFS= read -r -s bao_token
printf "\n"

if [[ -z "${bao_token}" ]]; then
  echo "No token entered; aborting." >&2
  exit 1
fi

printf '%s\n' "${bao_token}" | ssh "${remote_host}" \
  "set -euo pipefail
   mkdir -p ${remote_dir}
   sudo docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 ${container_name} sh -lc '
     set -eu
     IFS= read -r BAO_TOKEN
     export BAO_TOKEN
     bao status >/tmp/openbao-status-before-snapshot.txt
     bao operator raft snapshot save /tmp/${snapshot_name}
   '
   sudo docker cp ${container_name}:/tmp/${snapshot_name} ${remote_dir}/${snapshot_name}
   sudo docker cp ${container_name}:/tmp/openbao-status-before-snapshot.txt ${remote_dir}/openbao-status-before-${timestamp}.txt
   sudo chown dev_prod:dev_prod ${remote_dir}/${snapshot_name} ${remote_dir}/openbao-status-before-${timestamp}.txt
   cd ${remote_dir}
   sha256sum ${snapshot_name} > ${snapshot_name}.sha256
   sudo docker exec ${container_name} rm -f /tmp/${snapshot_name} /tmp/openbao-status-before-snapshot.txt >/dev/null 2>&1 || true"

scp "${remote_host}:openbao-migration/${snapshot_name}" "${local_dir}/${snapshot_name}"
scp "${remote_host}:openbao-migration/${snapshot_name}.sha256" "${local_dir}/${snapshot_name}.sha256"
scp "${remote_host}:openbao-migration/openbao-status-before-${timestamp}.txt" "${local_dir}/openbao-status-before-${timestamp}.txt"

(
  cd "${local_dir}"
  sha256sum -c "${snapshot_name}.sha256"
)

echo "Snapshot saved:"
echo "${local_dir}/${snapshot_name}"
