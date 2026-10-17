#!/usr/bin/env bash
# Per-tenant OpenBao AppRole for a customer's own ("tenant") Flowloom worker.
# Run it to see the guide: bash scripts/flowloom-tenant-worker-approle-openbao.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/scripts/lib/script-guide.sh"

tenant="${1:-}"
env_slug="${2:-}"
ttl="${3:-}"

script_guide <<'GUIDE'
Flowloom: OpenBao read role for one tenant's own worker
-------------------------------------------------------
Usage:  bash scripts/flowloom-tenant-worker-approle-openbao.sh [tenant] [env] [share-ttl]
        (anything left out is asked for below)

  tenant     the tenant slug = Keycloak organization alias, e.g. acme
  env        dev | staging | prod
  share-ttl  how long the hand-over token stays valid, e.g. 30m or 24h (default 24h)

What it does (safe to re-run):
  1. Policy + AppRole  flowloom-worker-<tenant>-<env>:
       READ  secret/flowloom/<tenant>/<env>/*            (that tenant's connections)
       DENY  secret/flowloom/<tenant>/<env>/_webhooks/*  (webhook credentials)
     so the customer's worker can never read another tenant's or environment's secrets.
  2. Issues a NEW secret_id, but only as a single-use WRAPPED token that expires
     after share-ttl. The secret itself never appears here or in any file.

It prints: the role_id and the wrapping token, plus the command the customer
runs once to unwrap the secret_id. Hand both over; if someone else unwraps the
token first, the customer's unwrap fails: run this again (new secret_id).
(Platform workers, run by MIAK IT, keep using flowloom-worker-<env>.)

It will ask for: missing values, then your OpenBao admin login.
GUIDE

ask_value tenant "Tenant (organization alias)" "" '^[a-z0-9][a-z0-9-]*$'
ask_value env_slug "Environment (dev/staging/prod)" "dev" '^[a-z0-9-]+$'
ask_value ttl "Hand-over token lifetime" "24h" '^[0-9]+[smh]$'

kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
openbao_addr="https://openbao.miak-it.com"
role="flowloom-worker-${tenant}-${env_slug}"

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

bao_exec() {
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_TOKEN=${BAO_TOKEN}" "$@"
}

printf '%s\n' "path \"secret/data/flowloom/${tenant}/${env_slug}/*\" {
  capabilities = [\"read\"]
}
path \"secret/metadata/flowloom/${tenant}/${env_slug}/*\" {
  capabilities = [\"read\", \"list\"]
}
path \"secret/data/flowloom/${tenant}/${env_slug}/_webhooks/*\" {
  capabilities = [\"deny\"]
}
path \"secret/metadata/flowloom/${tenant}/${env_slug}/_webhooks/*\" {
  capabilities = [\"deny\"]
}" |
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- \
    env "BAO_TOKEN=${BAO_TOKEN}" "POLICY_NAME=${role}" \
    sh -lc 'bao policy write "${POLICY_NAME}" -' >/dev/null

bao_exec bao write "auth/approle/role/${role}" \
  token_policies="${role}" \
  token_ttl="1h" \
  token_max_ttl="4h" \
  secret_id_ttl="0" \
  secret_id_num_uses="0" >/dev/null

role_id="$(bao_exec bao read -field=role_id "auth/approle/role/${role}/role-id")"
wrap_token="$(bao_exec bao write -f -wrap-ttl="${ttl}" -field=wrapping_token "auth/approle/role/${role}/secret-id")"

if [ -z "${wrap_token}" ]; then
  echo "Could not issue a wrapped secret_id for ${role}" >&2
  exit 1
fi

cat <<EOF2

Role ${role} is ready (read: secret/flowloom/${tenant}/${env_slug}/*, webhooks denied).

Hand these to ${tenant}'s worker operator:

  OPENBAO_ADDR=${openbao_addr}
  OPENBAO_ROLE_ID=${role_id}
  share token (single use, expires in ${ttl}): ${wrap_token}

They redeem the share token once to get OPENBAO_SECRET_ID:

  curl -s -X POST ${openbao_addr}/v1/sys/wrapping/unwrap -H "X-Vault-Token: ${wrap_token}"

("data.secret_id" in the response). The SDKs read OPENBAO_ADDR, OPENBAO_ROLE_ID
and OPENBAO_SECRET_ID; see the Flowloom repo's sdks/README.md.
EOF2

unset wrap_token role_id
