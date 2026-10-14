#!/usr/bin/env bash
# Bootstraps PER-ENVIRONMENT OpenBao AppRoles for Flowloom, which runs one
# engine per environment (dev / staging / prod; see Flowloom's
# docs/DECISIONS.md and docs/PROMOTION.md). For each environment it creates:
#
#   flowloom-worker-<env>  read-only on  secret/{data,metadata}/flowloom/+/<env>/*
#                          (workers of that environment fetch connection secrets)
#   flowloom-admin-<env>   create/update on secret/data/flowloom/+/<env>/*
#                          (that engine's Studio "Set Value"; no read at all)
#
# so a dev worker or the dev engine can never read or overwrite prod
# secrets. The "+" matches any tenant segment of
# secret/flowloom/<tenant>/<env>/<connection>.
#
# The old shared roles (flowloom-worker / flowloom-admin from
# flowloom-bootstrap-approle-openbao.sh and
# flowloom-bootstrap-admin-approle-openbao.sh) are left untouched, so nothing
# breaks: switch each engine and its workers to their environment's role,
# then delete the shared ones (see the end of this script's output).
#
# Usage:  bash scripts/flowloom-bootstrap-env-approles-openbao.sh [env ...]
#         (default: dev staging prod)
#
# Never echoes role_id/secret_id to stdout. Credentials go to chmod-600 files
# outside git, and are mirrored into apps/flowloom-<env> for a future k3s
# ExternalSecret, same conventions as the existing Flowloom scripts.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
openbao_addr="https://openbao.miak-it.com"

if [ "$#" -gt 0 ]; then
  environments=("$@")
else
  environments=(dev staging prod)
fi

for env_slug in "${environments[@]}"; do
  if ! [[ "${env_slug}" =~ ^[a-z0-9-]+$ ]]; then
    echo "Invalid environment slug: ${env_slug}" >&2
    exit 1
  fi
done

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

bao_exec() {
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_TOKEN=${BAO_TOKEN}" "$@"
}

bao_exec bao auth enable approle >/dev/null 2>&1 || true
bao_exec bao secrets enable -path=secret kv-v2 >/dev/null 2>&1 || true

write_policy() {
  local name="$1" policy="$2"
  printf '%s\n' "${policy}" |
    kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- \
      env "BAO_TOKEN=${BAO_TOKEN}" "POLICY_NAME=${name}" \
      sh -lc 'bao policy write "${POLICY_NAME}" -' >/dev/null
}

# create_role <role> <policy> <ttl> <max_ttl> -> writes role_id/secret_id into
# the caller's ROLE_ID / SECRET_ID variables (never printed).
create_role() {
  local role="$1" policy="$2" ttl="$3" max_ttl="$4"
  bao_exec bao write "auth/approle/role/${role}" \
    token_policies="${policy}" \
    token_ttl="${ttl}" \
    token_max_ttl="${max_ttl}" \
    secret_id_ttl="0" \
    secret_id_num_uses="0" >/dev/null

  ROLE_ID="$(bao_exec bao read -field=role_id "auth/approle/role/${role}/role-id")"
  SECRET_ID="$(bao_exec bao write -f -field=secret_id "auth/approle/role/${role}/secret-id")"
}

umask 077

for env_slug in "${environments[@]}"; do
  worker="flowloom-worker-${env_slug}"
  admin="flowloom-admin-${env_slug}"

  write_policy "${worker}" "path \"secret/data/flowloom/+/${env_slug}/*\" {
  capabilities = [\"read\"]
}
path \"secret/metadata/flowloom/+/${env_slug}/*\" {
  capabilities = [\"read\", \"list\"]
}"

  write_policy "${admin}" "path \"secret/data/flowloom/+/${env_slug}/*\" {
  capabilities = [\"create\", \"update\"]
}"

  create_role "${worker}" "${worker}" "1h" "4h"
  worker_role_id="${ROLE_ID}"
  worker_secret_id="${SECRET_ID}"

  create_role "${admin}" "${admin}" "15m" "1h"
  admin_role_id="${ROLE_ID}"
  admin_secret_id="${SECRET_ID}"
  unset ROLE_ID SECRET_ID

  worker_file="${HOME}/.flowloom-openbao-${env_slug}-worker-approle.env"
  admin_file="${HOME}/.flowloom-openbao-${env_slug}-admin-approle.env"

  {
    printf 'OPENBAO_ADDR=%s\n' "${openbao_addr}"
    printf 'OPENBAO_APPROLE_AUTH_PATH=approle\n'
    printf 'OPENBAO_ROLE_ID=%s\n' "${worker_role_id}"
    printf 'OPENBAO_SECRET_ID=%s\n' "${worker_secret_id}"
  } > "${worker_file}"

  # OPENBAO_ADMIN_ROLE_NAME lets the engine check at boot that it was given
  # its own environment's role (Flowloom.Vault.check_role/0).
  {
    printf 'OPENBAO_ADDR=%s\n' "${openbao_addr}"
    printf 'OPENBAO_APPROLE_AUTH_PATH=approle\n'
    printf 'OPENBAO_ADMIN_ROLE_NAME=%s\n' "${admin}"
    printf 'OPENBAO_ADMIN_ROLE_ID=%s\n' "${admin_role_id}"
    printf 'OPENBAO_ADMIN_SECRET_ID=%s\n' "${admin_secret_id}"
  } > "${admin_file}"
  chmod 600 "${worker_file}" "${admin_file}"

  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- \
    env "BAO_TOKEN=${BAO_TOKEN}" "KV_PATH=apps/flowloom-${env_slug}" "ADMIN_NAME=${admin}" \
      "W_ROLE=${worker_role_id}" "W_SECRET=${worker_secret_id}" \
      "A_ROLE=${admin_role_id}" "A_SECRET=${admin_secret_id}" \
    sh -lc 'bao kv put "${KV_PATH}" \
      OPENBAO_ROLE_ID="${W_ROLE}" OPENBAO_SECRET_ID="${W_SECRET}" \
      OPENBAO_ADMIN_ROLE_NAME="${ADMIN_NAME}" \
      OPENBAO_ADMIN_ROLE_ID="${A_ROLE}" OPENBAO_ADMIN_SECRET_ID="${A_SECRET}"' >/dev/null

  unset worker_role_id worker_secret_id admin_role_id admin_secret_id

  echo "[${env_slug}] ${worker}: read  secret/{data,metadata}/flowloom/+/${env_slug}/*  -> ${worker_file}"
  echo "[${env_slug}] ${admin}:  write secret/data/flowloom/+/${env_slug}/* (no read) -> ${admin_file}"
done

cat <<EOF

Done. All credential files are chmod 600 and outside git. Mirrored to apps/flowloom-<env>.

Next steps:
  1. Each engine: source its admin file into the engine's environment, e.g. for prod:
       set -a; . ~/.flowloom-openbao-prod-admin-approle.env; set +a
     The engine logs the role at boot and refuses to start if the role isn't its own environment's.
  2. Each environment's workers: use that environment's worker file
     (OPENBAO_ROLE_ID / OPENBAO_SECRET_ID), never another environment's.
  3. Once every engine and worker is switched, delete the old shared roles:
       flowloom-worker, flowloom-admin  (auth/approle/role/<name> and the policies of the same name)
EOF
