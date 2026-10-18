#!/usr/bin/env bash
# OpenBao role for the Flowloom connector worker (flowloom-connectors repo),
# so OpenBao issues AND rotates the Microsoft app secrets by itself.
# Run it to see the guide: bash scripts/flowloom-connectors-approle-openbao.sh [env ...]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/scripts/lib/script-guide.sh"

environments=("$@")
[ "${#environments[@]}" -gt 0 ] || environments=(dev)

script_guide <<'GUIDE'
Flowloom connectors: OpenBao rotates the Microsoft secrets, nobody by hand
------------------------------------------------------------------------
Usage:  bash scripts/flowloom-connectors-approle-openbao.sh [env ...]   (default: dev)

Per environment:
  1. Policy + AppRole flowloom-connectors-<env> for the connector worker only:
     read connections (secret/flowloom/+/<env>/*) and read
     azure/creds/flowloom-mail-reader and -onedrive-reader. Sessions last 24h
     and can be renewed up to 30 days; the connector renews its session and
     rotates the Microsoft secret before it ends. Nothing for a person to renew.
     Credentials go to ~/.flowloom-openbao-<env>-connectors-approle.env (0600).
  2. Switches the connections microsoft-mail and microsoft-files (tenant you
     choose) to {tenant_id, openbao_azure_role}: no secret is stored in them
     any more; the connector gets it from OpenBao itself.
  3. Optional: ends the old 30-day sessions from flowloom-connection-microsoft.sh
     (paste their accessors), so OpenBao deletes those copied secrets.

It asks for: your OpenBao admin login, the tenant slug, optional accessors.
Nothing secret is printed.
GUIDE

kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
openbao_addr="https://openbao.miak-it.com"

for env_slug in "${environments[@]}"; do
  [[ "${env_slug}" =~ ^[a-z0-9-]+$ ]] || { echo "Invalid environment: ${env_slug}" >&2; exit 1; }
done

tenant="${FLOWLOOM_TENANT:-}"
ask_value tenant "Flowloom tenant slug (for the connections)" "miak-it" '^[a-z0-9-]+$'

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

bao_exec() {
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- env "BAO_TOKEN=${BAO_TOKEN}" "$@"
}

umask 077
tenant_id="$(bao_exec bao kv get -field=tenant_id apps/masteradmin)"

for env_slug in "${environments[@]}"; do
  role="flowloom-connectors-${env_slug}"

  bao_exec sh -c 'bao policy write "$0" -' "${role}" >/dev/null <<POLICY
path "secret/data/flowloom/+/${env_slug}/*" { capabilities = ["read"] }
path "secret/metadata/flowloom/+/${env_slug}/*" { capabilities = ["read", "list"] }
path "azure/creds/flowloom-mail-reader" { capabilities = ["read"] }
path "azure/creds/flowloom-onedrive-reader" { capabilities = ["read"] }
POLICY

  bao_exec bao write "auth/approle/role/${role}" \
    token_policies="${role}" token_ttl="24h" token_max_ttl="720h" \
    secret_id_ttl="0" secret_id_num_uses="0" >/dev/null
  role_id="$(bao_exec bao read -field=role_id "auth/approle/role/${role}/role-id")"
  secret_id="$(bao_exec bao write -f -field=secret_id "auth/approle/role/${role}/secret-id")"

  env_file="${HOME}/.flowloom-openbao-${env_slug}-connectors-approle.env"
  {
    printf 'OPENBAO_ADDR=%s\n' "${openbao_addr}"
    printf 'OPENBAO_APPROLE_AUTH_PATH=approle\n'
    printf 'OPENBAO_ROLE_ID=%s\n' "${role_id}"
    printf 'OPENBAO_SECRET_ID=%s\n' "${secret_id}"
  } > "${env_file}"
  unset role_id secret_id
  echo "[${env_slug}] AppRole ${role} ready -> ${env_file}"

  for pair in "microsoft-mail:flowloom-mail-reader" "microsoft-files:flowloom-onedrive-reader"; do
    conn="${pair%%:*}"; azure_role="${pair##*:}"
    jq -n --arg t "${tenant_id}" --arg r "${azure_role}" '{tenant_id: $t, openbao_azure_role: $r}' \
      | bao_exec bao kv put "secret/flowloom/${tenant}/${env_slug}/${conn}" - >/dev/null
    echo "[${env_slug}] ${conn}: now names OpenBao role ${azure_role} (no secret stored)"
  done
done
unset tenant_id

printf 'Accessors of old 30-day sessions to end (space-separated, Enter to skip): '
IFS= read -r accessors </dev/tty || accessors=""
for a in ${accessors}; do
  [[ "${a}" =~ ^[A-Za-z0-9.]+$ ]] || { echo "skipping invalid accessor ${a}" >&2; continue; }
  if bao_exec bao token revoke -accessor "${a}" >/dev/null 2>&1; then
    echo "Ended session ${a} (OpenBao deletes its Microsoft secret)."
  else
    echo "Could not end session ${a} (already gone?)." >&2
  fi
done

echo "Done. Run the connector with the new env file; OpenBao handles the secrets from now on."
