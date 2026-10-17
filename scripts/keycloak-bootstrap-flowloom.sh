#!/usr/bin/env bash
# Step 2 of the Keycloak setup (Keycloak running), see the Flowloom repo's
# docs/IAM.md. In realm "flowloom" it:
#   - creates the organization "MIAK IT" (alias miak-it = Flowloom tenant slug)
#   - creates your user (password asked here, never printed or stored), makes
#     it a member of the organization and gives it the tenant-admin role
#   - generates the flowloom-studio client secret (only if none is stored yet,
#     or with --rotate) into OpenBao apps/flowloom-<env> (dev, staging, prod)
#     as KEYCLOAK_ISSUER / KEYCLOAK_CLIENT_ID / KEYCLOAK_CLIENT_SECRET, and into
#     ~/.flowloom-keycloak.env (chmod 600) for the local dev engine.
# Re-running is safe: existing org, user and membership are kept.

# Run it to see the guide: bash scripts/keycloak-bootstrap-flowloom.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/scripts/lib/script-guide.sh"

rotate=false
args=()
for a in "$@"; do
  if [ "$a" = "--rotate" ]; then rotate=true; else args+=("$a"); fi
done
username="${args[0]:-}"
email="${args[1]:-}"
first="${args[2]:-}"
last="${args[3]:-}"

script_guide <<'GUIDE'
Keycloak: add a Flowloom user (realm "flowloom") + Studio client secret
------------------------------------------------------------------------
Usage:  bash scripts/keycloak-bootstrap-flowloom.sh [username] [email] [first] [last] [--rotate]
        (anything left out is asked for below)

What it does (safe to re-run; existing things are kept):
  1. Organization "MIAK IT" (alias miak-it = Flowloom tenant): created if missing.
  2. The user: created if missing (you type its password, hidden, twice),
     added to miak-it, given the tenant-admin role.
  3. Client secret of flowloom-studio: only generated if none is stored yet,
     or with --rotate (the old one stops working at once; restart engines).
     Stored in OpenBao apps/flowloom-{dev,staging,prod} + ~/.flowloom-keycloak.env

It will ask for: missing arguments, your OpenBao admin login (it reads the
Keycloak admin from apps/keycloak-admin), and the new user's password (new
users only).
GUIDE

ask_value username "Username" "" '^[a-z0-9._-]+$'
ask_value email "Email" "" '^[^@[:space:]]+@[^@[:space:]]+$'
if [ "${#args[@]}" -lt 3 ] && [ -t 0 ]; then
  printf 'First name (optional): '; IFS= read -r first
  printf 'Last name (optional): '; IFS= read -r last
fi

kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
realm="flowloom"
client_id="flowloom-studio"
issuer="https://auth.miak-it.com/realms/${realm}"
org_alias="miak-it"
org_name="MIAK IT"
org_domain="miak-it.com"
envs=(dev staging prod)

kc_pod="$(kubectl --kubeconfig "${kubeconfig}" -n keycloak get pod -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}')"

# Administrative credentials live in OpenBao, never in the Keycloak pod env.
source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

bao() {
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- env "BAO_TOKEN=${BAO_TOKEN}" "$@"
}
admin_username="$(bao bao kv get -field=KC_ADMIN_USERNAME apps/keycloak-admin)"
admin_password="$(bao bao kv get -field=KC_ADMIN_PASSWORD apps/keycloak-admin)"

kc() {
  printf '%s\n%s\n' "${admin_username}" "${admin_password}" |
    kubectl --kubeconfig "${kubeconfig}" -n keycloak exec -i "${kc_pod}" -- sh -c '
      set -eu
      IFS= read -r admin_user
      IFS= read -r admin_pw
      config="$(mktemp /tmp/kcadm.XXXXXX)"
      chmod 600 "$config"
      trap "rm -f -- $config" EXIT
      /opt/keycloak/bin/kcadm.sh config credentials --config "$config" --server http://localhost:8080 \
        --realm master --user "$admin_user" --password "$admin_pw" >/dev/null 2>&1
      /opt/keycloak/bin/kcadm.sh "$@" --config "$config"' kcadm "$@"
}

# -- organization -------------------------------------------------------------
org_id="$(kc get organizations -r "${realm}" -q search="${org_alias}" --fields id,alias --format csv --noquotes |
  awk -F, -v a="${org_alias}" '$2 == a { print $1 }' | head -1)"
if [ -z "${org_id}" ]; then
  kc create organizations -r "${realm}" -s name="${org_name}" -s alias="${org_alias}" \
    -s "domains=[{\"name\":\"${org_domain}\"}]" >/dev/null
  org_id="$(kc get organizations -r "${realm}" -q search="${org_alias}" --fields id,alias --format csv --noquotes |
    awk -F, -v a="${org_alias}" '$2 == a { print $1 }' | head -1)"
  echo "Created organization ${org_name} (${org_alias})."
else
  echo "Organization ${org_alias} exists."
fi

# -- user ---------------------------------------------------------------------
user_id="$(kc get users -r "${realm}" -q username="${username}" -q exact=true --fields id --format csv --noquotes | head -1)"
if [ -z "${user_id}" ]; then
  printf "New password for %s (min 12 chars): " "${username}"
  IFS= read -r -s password; printf "\n"
  printf "Repeat: "
  IFS= read -r -s password2; printf "\n"
  [ "${password}" = "${password2}" ] || { echo "passwords differ" >&2; exit 1; }
  unset password2

  kc create users -r "${realm}" -s username="${username}" -s email="${email}" \
    -s firstName="${first}" -s lastName="${last}" -s enabled=true -s emailVerified=true >/dev/null
  kc set-password -r "${realm}" --username "${username}" --new-password "${password}"
  unset password
  user_id="$(kc get users -r "${realm}" -q username="${username}" -q exact=true --fields id --format csv --noquotes | head -1)"
  echo "Created user ${username}."
else
  echo "User ${username} exists (password unchanged)."
fi

if ! kc get "organizations/${org_id}/members" -r "${realm}" --fields id --format csv --noquotes | grep -qx "${user_id}"; then
  kc create "organizations/${org_id}/members" -r "${realm}" -b "\"${user_id}\"" >/dev/null
  echo "Added ${username} to ${org_alias}."
fi
kc add-roles -r "${realm}" --uusername "${username}" --cclientid "${client_id}" --rolename tenant-admin
echo "${username} has role tenant-admin."

# -- client secret ------------------------------------------------------------
if [ "${rotate}" = false ] && bao bao kv get -field=KEYCLOAK_CLIENT_SECRET "apps/flowloom-dev" >/dev/null 2>&1; then
  echo "Client secret already stored (use --rotate to replace it)."
  exit 0
fi

client_uuid="$(kc get clients -r "${realm}" -q clientId="${client_id}" --fields id --format csv --noquotes | head -1)"
client_secret="$(kc create "clients/${client_uuid}/client-secret" -r "${realm}" -o | jq -r '.value // empty')"
[ -n "${client_secret}" ] || { echo "could not generate the client secret" >&2; exit 1; }

for env_slug in "${envs[@]}"; do
  # patch keeps the AppRole values already at apps/flowloom-<env>; put if it doesn't exist yet.
  bao "KV_PATH=apps/flowloom-${env_slug}" "ISS=${issuer}" "CID=${client_id}" "CSEC=${client_secret}" sh -lc '
    bao kv patch "${KV_PATH}" KEYCLOAK_ISSUER="${ISS}" KEYCLOAK_CLIENT_ID="${CID}" KEYCLOAK_CLIENT_SECRET="${CSEC}" >/dev/null 2>&1 ||
    bao kv put "${KV_PATH}" KEYCLOAK_ISSUER="${ISS}" KEYCLOAK_CLIENT_ID="${CID}" KEYCLOAK_CLIENT_SECRET="${CSEC}" >/dev/null'
done

env_file="${HOME}/.flowloom-keycloak.env"
(
  umask 077
  {
    printf 'KEYCLOAK_ISSUER=%s\n' "${issuer}"
    printf 'KEYCLOAK_CLIENT_ID=%s\n' "${client_id}"
    printf 'KEYCLOAK_CLIENT_SECRET=%s\n' "${client_secret}"
  } > "${env_file}"
)
chmod 600 "${env_file}"
unset client_secret

cat <<NEXT
Client secret for ${client_id} stored in apps/flowloom-{dev,staging,prod} and ${env_file}.
(Any previous secret stopped working just now.)

Local dev engine: add to its environment, e.g.
  set -a; . ~/.flowloom-keycloak.env; set +a
NEXT
