#!/usr/bin/env bash
# Bootstraps the "flowloom-worker" AppRole on the shared OpenBao instance so
# Flowloom workers (which may run outside k3s, e.g. on a dev machine) can
# fetch their own secrets live, per docs/ARCHITECTURE.md's "secrets fetched
# just-in-time by the worker, never baked into env at startup" decision.
#
# Unlike the Kubernetes-auth/External-Secrets pattern used for static
# per-app env vars (n8n, windmill, miak-website — see
# openbao-bootstrap-kubernetes-auth.sh), this mints role_id/secret_id
# credentials a worker process authenticates with directly, then reads
# secrets from `secret/flowloom/<tenant>/<environment>/<connection-name>`
# (the `secret/` KV mount, same one kids-prep's AppRole already uses — not
# the ESO-only `apps/` mount).
#
# Never echoes role_id/secret_id to stdout — writes them straight to a local
# file outside git, per the "don't print OpenBao tokens into chat/git" rule
# in the AI Project Onboarding Context page. Also stores them in
# apps/flowloom (mirroring kids-prep's convention) so a future k3s
# deployment of Flowloom can pull them in via the same ExternalSecret
# pattern once it exists.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
policy_name="flowloom-worker"
role_name="flowloom-worker"
output_file="${HOME}/.flowloom-openbao-approle.env"

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
  capabilities = ["read"]
}

path "secret/metadata/flowloom/*" {
  capabilities = ["read", "list"]
}
POLICY

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" bao write "auth/approle/role/${role_name}" \
    token_policies="${policy_name}" \
    token_ttl="1h" \
    token_max_ttl="4h" \
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
  printf 'OPENBAO_ROLE_ID=%s\n' "${role_id}"
  printf 'OPENBAO_SECRET_ID=%s\n' "${secret_id}"
} > "${output_file}"
chmod 600 "${output_file}"

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- \
  env "BAO_TOKEN=${BAO_TOKEN}" "ROLE_ID=${role_id}" "SECRET_ID=${secret_id}" \
  sh -lc 'bao kv put apps/flowloom OPENBAO_ROLE_ID="${ROLE_ID}" OPENBAO_SECRET_ID="${SECRET_ID}"' \
  >/dev/null

unset role_id secret_id

echo "OpenBao AppRole configured for Flowloom workers."
echo "Policy: ${policy_name} (read secret/data/flowloom/*, secret/metadata/flowloom/*)"
echo "Role: ${role_name}"
echo "Credentials written to: ${output_file} (chmod 600, not in git)"
echo "Also stored in apps/flowloom for a future k3s ExternalSecret, mirroring kids-prep's pattern."
