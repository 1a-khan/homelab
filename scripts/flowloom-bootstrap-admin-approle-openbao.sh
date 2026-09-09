#!/usr/bin/env bash
# Bootstraps the "flowloom-admin" AppRole on the shared OpenBao instance --
# this is the credential Flowloom's own backend (not a worker) uses to
# WRITE a connection's secret value from the Studio "Connections" page
# ("credentials input layer"). Deliberately a SEPARATE AppRole from
# flowloom-worker (see flowloom-bootstrap-approle-openbao.sh): that one is
# read-only, this one is write-only (create/update, no read capability at
# all) -- so even if Flowloom's own code somehow tried to read a secret
# back, OpenBao itself would refuse it. Only workers ever read secrets.
#
# Never echoes role_id/secret_id to stdout -- writes them straight to a
# local file outside git, same as flowloom-bootstrap-approle-openbao.sh.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
policy_name="flowloom-admin"
role_name="flowloom-admin"
output_file="${HOME}/.flowloom-openbao-admin-approle.env"

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" bao auth enable approle >/dev/null 2>&1 || true

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" bao secrets enable -path=secret kv-v2 >/dev/null 2>&1 || true

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" "POLICY_NAME=${policy_name}" \
  sh -lc 'bao policy write "${POLICY_NAME}" -' <<'POLICY'
path "secret/data/flowloom/*" {
  capabilities = ["create", "update"]
}
POLICY

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" bao write "auth/approle/role/${role_name}" \
    token_policies="${policy_name}" \
    token_ttl="15m" \
    token_max_ttl="1h" \
    secret_id_ttl="0" \
    secret_id_num_uses="0"

role_id="$(
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_TOKEN=${BAO_TOKEN}" bao read -field=role_id "auth/approle/role/${role_name}/role-id"
)"

secret_id="$(
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_TOKEN=${BAO_TOKEN}" bao write -f -field=secret_id "auth/approle/role/${role_name}/secret-id"
)"

umask 077
{
  printf 'OPENBAO_ADDR=https://openbao.miak-it.com\n'
  printf 'OPENBAO_APPROLE_AUTH_PATH=approle\n'
  printf 'OPENBAO_ADMIN_ROLE_ID=%s\n' "${role_id}"
  printf 'OPENBAO_ADMIN_SECRET_ID=%s\n' "${secret_id}"
} > "${output_file}"
chmod 600 "${output_file}"

unset role_id secret_id

echo "OpenBao admin (write-only) AppRole configured for Flowloom's Connections UI."
echo "Policy: ${policy_name} (create/update only on secret/data/flowloom/* -- no read)"
echo "Role: ${role_name}"
echo "Credentials written to: ${output_file} (chmod 600, not in git)"
echo "Source this into the Flowloom dev server's env alongside .flowloom-openbao-approle.env,"
echo "then restart 'mix phx.server' so config/dev.exs picks up OPENBAO_ADMIN_ROLE_ID/OPENBAO_ADMIN_SECRET_ID."
