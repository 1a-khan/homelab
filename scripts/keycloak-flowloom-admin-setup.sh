#!/usr/bin/env bash
# One-time Keycloak setup for Flowloom's admin screens (tenants, departments,
# people are then managed in Studio). Run it to see the guide:
#   bash scripts/keycloak-flowloom-admin-setup.sh
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

script_guide <<'GUIDE'
Flowloom: one-time Keycloak setup for the admin screens
-------------------------------------------------------
Usage:  bash scripts/keycloak-flowloom-admin-setup.sh [platform-admin-username] [email] [--rotate]

After this, tenants, departments and people are managed in Flowloom Studio
(Tenants / Team). This script only sets up what Studio itself can't (safe to re-run):

  1. Groups /flowloom-platform-admins and /tenants (departments live below it)
  2. A "flowloom groups" mapper on client flowloom-studio, so the login token
     carries group paths (admin rights and department roles per tenant)
  3. Service account client flowloom-admin-api, limited to users, groups and
     organizations (it can't change realm settings or clients). Its secret goes
     to OpenBao apps/flowloom-{dev,staging,prod} (KEYCLOAK_ADMIN_CLIENT_SECRET)
     and ~/.flowloom-keycloak.env. Only generated if none is stored, or with --rotate.
  4. The first platform admin: an existing user, or a new one (you type the
     password, hidden). Added to /flowloom-platform-admins.
  5. If that user is in the MIAK IT organization: added to /tenants/miak-it/admins,
     so they stay tenant admin there (the old global client roles are no longer used).

It will ask for: missing values, your OpenBao admin login (it reads the Keycloak
admin from apps/keycloak-admin), and a password only if the user is new.
Afterwards: restart the Flowloom dev engine, sign out and in again.
GUIDE

ask_value username "Platform admin username" "ammad.khan" '^[a-z0-9._@-]+$'

kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
realm="flowloom"
studio_client="flowloom-studio"
admin_client="flowloom-admin-api"
envs=(dev staging prod)
admin_api_roles=(manage-users view-users query-users query-groups manage-organizations view-organizations query-organizations)

kc_pod="$(kubectl --kubeconfig "${kubeconfig}" -n keycloak get pod -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}')"

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

bao() {
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- env "BAO_TOKEN=${BAO_TOKEN}" "$@"
}
admin_username="$(bao bao kv get -field=KC_ADMIN_USERNAME apps/keycloak-admin)"
admin_password="$(bao bao kv get -field=KC_ADMIN_PASSWORD apps/keycloak-admin)"

# kcadm in the Keycloak pod; admin credentials go in over stdin, never argv.
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

# -- 1. groups ------------------------------------------------------------------
top_group_id() {
  kc get groups -r "${realm}" -q search="$1" -q exact=true --fields id,name --format csv --noquotes |
    awk -F, -v n="$1" '$2 == n { print $1 }' | head -1
}
for group in flowloom-platform-admins tenants; do
  if [ -z "$(top_group_id "${group}")" ]; then
    kc create groups -r "${realm}" -s name="${group}" >/dev/null 2>&1
    echo "Created group /${group}."
  fi
done
platform_group="$(top_group_id flowloom-platform-admins)"
tenants_group="$(top_group_id tenants)"

# -- 2. group mapper on the Studio client ----------------------------------------
studio_uuid="$(kc get clients -r "${realm}" -q clientId="${studio_client}" --fields id --format csv --noquotes | head -1)"
if ! kc get "clients/${studio_uuid}/protocol-mappers/models" -r "${realm}" --fields name --format csv --noquotes | grep -qx "flowloom groups"; then
  kc create "clients/${studio_uuid}/protocol-mappers/models" -r "${realm}" \
    -s name="flowloom groups" -s protocol=openid-connect -s protocolMapper=oidc-group-membership-mapper \
    -s 'config."claim.name"=flowloom_groups' -s 'config."full.path"=true' \
    -s 'config."id.token.claim"=true' -s 'config."access.token.claim"=true' \
    -s 'config."userinfo.token.claim"=true' >/dev/null
  echo "Added the flowloom groups mapper to ${studio_client}."
fi

# -- 3. admin service account ------------------------------------------------------
admin_uuid="$(kc get clients -r "${realm}" -q clientId="${admin_client}" --fields id --format csv --noquotes | head -1)"
if [ -z "${admin_uuid}" ]; then
  kc create clients -r "${realm}" -s clientId="${admin_client}" -s enabled=true -s publicClient=false \
    -s serviceAccountsEnabled=true -s standardFlowEnabled=false -s directAccessGrantsEnabled=false \
    -s implicitFlowEnabled=false -s clientAuthenticatorType=client-secret \
    -s 'description=Flowloom admin screens: users, groups, organizations only' >/dev/null 2>&1
  admin_uuid="$(kc get clients -r "${realm}" -q clientId="${admin_client}" --fields id --format csv --noquotes | head -1)"
  echo "Created client ${admin_client}."
  rotate=true
fi
for role in "${admin_api_roles[@]}"; do
  kc add-roles -r "${realm}" --uusername "service-account-${admin_client}" --cclientid realm-management --rolename "${role}"
done
echo "${admin_client} may manage users, groups and organizations (nothing else)."

if [ "${rotate}" = true ] || ! bao bao kv get -field=KEYCLOAK_ADMIN_CLIENT_SECRET "apps/flowloom-dev" >/dev/null 2>&1; then
  admin_secret="$(kc create "clients/${admin_uuid}/client-secret" -r "${realm}" -o | jq -r '.value // empty')"
  [ -n "${admin_secret}" ] || { echo "could not generate the ${admin_client} secret" >&2; exit 1; }

  for env_slug in "${envs[@]}"; do
    bao "KV_PATH=apps/flowloom-${env_slug}" "SEC=${admin_secret}" sh -lc '
      bao kv patch "${KV_PATH}" KEYCLOAK_ADMIN_CLIENT_SECRET="${SEC}" >/dev/null 2>&1 ||
      bao kv put "${KV_PATH}" KEYCLOAK_ADMIN_CLIENT_SECRET="${SEC}" >/dev/null'
  done

  env_file="${HOME}/.flowloom-keycloak.env"
  (
    umask 077
    touch "${env_file}"
    grep -v '^KEYCLOAK_ADMIN_CLIENT_SECRET=' "${env_file}" > "${env_file}.tmp" || true
    printf 'KEYCLOAK_ADMIN_CLIENT_SECRET=%s\n' "${admin_secret}" >> "${env_file}.tmp"
    mv "${env_file}.tmp" "${env_file}"
  )
  chmod 600 "${env_file}"
  unset admin_secret
  echo "Stored the ${admin_client} secret in apps/flowloom-{dev,staging,prod} and ${env_file}."
else
  echo "${admin_client} secret already stored (use --rotate to replace it)."
fi

# -- 4. platform admin -------------------------------------------------------------
user_id="$(kc get users -r "${realm}" -q username="${username}" -q exact=true --fields id --format csv --noquotes | head -1)"
if [ -z "${user_id}" ]; then
  ask_value email "Email of the new platform admin" "" '^[^@[:space:]]+@[^@[:space:]]+$'
  printf "New password for %s (min 12 chars): " "${username}"
  IFS= read -r -s password; printf "\n"
  printf "Repeat: "
  IFS= read -r -s password2; printf "\n"
  [ "${password}" = "${password2}" ] || { echo "passwords differ" >&2; exit 1; }
  unset password2
  kc create users -r "${realm}" -s username="${username}" -s email="${email}" -s enabled=true -s emailVerified=true >/dev/null
  kc set-password -r "${realm}" --username "${username}" --new-password "${password}"
  unset password
  user_id="$(kc get users -r "${realm}" -q username="${username}" -q exact=true --fields id --format csv --noquotes | head -1)"
  echo "Created user ${username}."
fi
kc update "users/${user_id}/groups/${platform_group}" -r "${realm}" -n >/dev/null
echo "${username} is a platform admin."

# -- 5. keep MIAK IT admin rights ---------------------------------------------------
miak_org="$(kc get organizations -r "${realm}" --fields id,alias --format csv --noquotes | awk -F, '$2 == "miak-it" { print $1 }' | head -1)"
if [ -n "${miak_org}" ] && kc get "organizations/${miak_org}/members" -r "${realm}" --fields id --format csv --noquotes | grep -qx "${user_id}"; then
  miak_group="$(kc get "groups/${tenants_group}/children" -r "${realm}" --fields id,name --format csv --noquotes | awk -F, '$2 == "miak-it" { print $1 }' | head -1)"
  if [ -z "${miak_group}" ]; then
    kc create "groups/${tenants_group}/children" -r "${realm}" -s name=miak-it >/dev/null 2>&1
    miak_group="$(kc get "groups/${tenants_group}/children" -r "${realm}" --fields id,name --format csv --noquotes | awk -F, '$2 == "miak-it" { print $1 }' | head -1)"
  fi
  admins_group="$(kc get "groups/${miak_group}/children" -r "${realm}" --fields id,name --format csv --noquotes | awk -F, '$2 == "admins" { print $1 }' | head -1)"
  if [ -z "${admins_group}" ]; then
    kc create "groups/${miak_group}/children" -r "${realm}" -s name=admins >/dev/null 2>&1
    admins_group="$(kc get "groups/${miak_group}/children" -r "${realm}" --fields id,name --format csv --noquotes | awk -F, '$2 == "admins" { print $1 }' | head -1)"
  fi
  kc update "users/${user_id}/groups/${admins_group}" -r "${realm}" -n >/dev/null
  echo "${username} stays tenant admin of MIAK IT (/tenants/miak-it/admins)."
fi

cat <<NEXT

Done. Restart the Flowloom dev engine (it reads ~/.flowloom-keycloak.env), then
sign out and in again: the user menu shows "Tenants" and "Team".
NEXT
