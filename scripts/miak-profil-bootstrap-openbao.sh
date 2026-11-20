#!/usr/bin/env bash
# Stores the secrets of the application profile (ammad.miak-it.dev) in OpenBao:
#   PROFILE_SECRET       cookie signing key (generated; rotating it logs every visitor out)
#   PROFILE_WEBHOOK_URL  n8n webhook that sends a Telegram message on every visit
# Usage: scripts/miak-profil-bootstrap-openbao.sh <n8n-webhook-url>
# External Secrets syncs both into the miak-profil namespace within a minute.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"

# shellcheck source=lib/openbao-login.sh
source "${repo_root}/scripts/lib/openbao-login.sh"

PROFILE_WEBHOOK_URL="${1:-}"
if [[ -z "${PROFILE_WEBHOOK_URL}" ]]; then
  echo "Usage: $0 <n8n-webhook-url>" >&2
  exit 1
fi

openbao_login_admin admin
trap openbao_revoke_login_token EXIT

PROFILE_SECRET="$(openssl rand -hex 32)"
kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" "PROFILE_SECRET=${PROFILE_SECRET}" "PROFILE_WEBHOOK_URL=${PROFILE_WEBHOOK_URL}" \
  sh -lc 'bao kv put apps/miak-profil PROFILE_SECRET="${PROFILE_SECRET}" PROFILE_WEBHOOK_URL="${PROFILE_WEBHOOK_URL}" >/dev/null'
unset PROFILE_SECRET PROFILE_WEBHOOK_URL
echo "Stored apps/miak-profil (PROFILE_SECRET, PROFILE_WEBHOOK_URL)."
