#!/usr/bin/env bash
# Writes one throwaway secret under secret/flowloom/miak-it/dev/demo_connection
# so the flowloom-worker AppRole (see flowloom-bootstrap-approle-openbao.sh)
# has something real to fetch during end-to-end verification. Not something
# an app ever does itself -- Flowloom's engine never writes secret values,
# only reads a path -- this is purely a manual test fixture.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
path="secret/flowloom/miak-it/dev/demo_connection"

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" "PATH_=${path}" \
  sh -lc 'bao kv put "${PATH_}" api_key=demo-value-12345'

echo "Seeded demo secret at ${path} (api_key=demo-value-12345, for verification only)."
