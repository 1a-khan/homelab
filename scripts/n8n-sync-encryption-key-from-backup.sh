#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
backup_dir="${repo_root}/backups/n8n"
data_tgz="${1:-$(ls -t "${backup_dir}"/n8n-data-*.tgz 2>/dev/null | head -n 1 || true)}"

if [[ -z "${data_tgz}" || ! -f "${data_tgz}" ]]; then
  echo "Missing n8n data archive." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to read the n8n config JSON." >&2
  exit 1
fi

encryption_key="$(tar -xOzf "${data_tgz}" ./config | jq -r '.encryptionKey // empty')"

if [[ -z "${encryption_key}" || "${encryption_key}" == "null" ]]; then
  echo "Could not read encryptionKey from ${data_tgz}." >&2
  exit 1
fi

namespace="openbao"
pod="openbao-0"
source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

kubectl --kubeconfig "${kubeconfig}" -n openbao exec openbao-0 -- \
  env "BAO_TOKEN=${BAO_TOKEN}" \
  bao kv patch apps/n8n "N8N_ENCRYPTION_KEY=${encryption_key}" >/dev/null

unset encryption_key

kubectl --kubeconfig "${kubeconfig}" annotate externalsecret -n n8n n8n \
  force-sync="$(date +%s)" --overwrite >/dev/null

echo "n8n encryption key synced from backup config into OpenBao and ExternalSecret reconciliation requested."
