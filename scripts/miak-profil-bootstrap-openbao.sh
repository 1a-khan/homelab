#!/usr/bin/env bash
# Creates the signing secret of the application profile (ammad.cokha.com) in OpenBao.
# Run once; External Secrets syncs it into the miak-profil namespace.
# Rotating it logs every visitor out (their cookies no longer verify).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"

# shellcheck source=lib/openbao-login.sh
source "${repo_root}/scripts/lib/openbao-login.sh"

openbao_login_admin admin
trap openbao_revoke_login_token EXIT

PROFILE_SECRET="$(openssl rand -hex 32)"
kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" "PROFILE_SECRET=${PROFILE_SECRET}" \
  sh -lc 'bao kv put apps/miak-profil PROFILE_SECRET="${PROFILE_SECRET}" >/dev/null'
unset PROFILE_SECRET
echo "Stored apps/miak-profil (PROFILE_SECRET)."
