#!/usr/bin/env bash
# "Sign in with Microsoft" for Flowloom (realm flowloom): Microsoft work,
# school and personal accounts (outlook.com, msn.com, hotmail.com).
# Run it to see the guide:
#   bash scripts/keycloak-microsoft-login-setup.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/scripts/lib/script-guide.sh"

script_guide <<'GUIDE'
Flowloom: "Sign in with Microsoft"
----------------------------------
Usage:  bash scripts/keycloak-microsoft-login-setup.sh

Needs the Entra app registration "Flowloom login (Keycloak)":
  - account types: any Entra tenant AND personal Microsoft accounts
  - redirect URI (Web): https://auth.miak-it.com/realms/flowloom/broker/microsoft/endpoint
  - a client secret (24 months)

What it does (safe to re-run, e.g. when the secret is renewed):
  1. Stores the client id and secret in OpenBao apps/keycloak-microsoft
  2. Adds (or updates) the identity provider "microsoft" in realm flowloom:
     the login page gets a "Microsoft" button.

Safety: Microsoft accounts are never linked to existing accounts by email
(trustEmail off; anyone can put any address on a user in their own Entra
tenant). A new person gets a new account WITHOUT any Flowloom rights; they
wait for approval in Flowloom. Linking to an existing account asks for that
account's password.

It will ask for: the client id, the client secret (hidden), and your OpenBao
admin login (it reads the Keycloak admin from apps/keycloak-admin).
GUIDE

ask_value client_id "Application (client) ID" "" '^[0-9a-fA-F-]{36}$'
printf "Client secret (Value, hidden): "
IFS= read -r -s client_secret; printf "\n"
[ -n "${client_secret}" ] || { echo "no secret given" >&2; exit 1; }

kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
realm="flowloom"
alias="microsoft"

kc_pod="$(kubectl --kubeconfig "${kubeconfig}" -n keycloak get pod -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}')"

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin

bao() {
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- env "BAO_TOKEN=${BAO_TOKEN}" "$@"
}

# -- 1. OpenBao -------------------------------------------------------------------
# The secret goes in over stdin (never argv: process lists and shell history).
printf '%s\n%s\n' "${client_id}" "${client_secret}" |
  bao sh -lc '
    set -eu
    IFS= read -r id
    IFS= read -r secret
    bao kv put apps/keycloak-microsoft MS_CLIENT_ID="$id" MS_CLIENT_SECRET="$secret" >/dev/null'
echo "Stored the client id and secret in OpenBao apps/keycloak-microsoft."

admin_username="$(bao bao kv get -field=KC_ADMIN_USERNAME apps/keycloak-admin)"
admin_password="$(bao bao kv get -field=KC_ADMIN_PASSWORD apps/keycloak-admin)"

# kcadm in the Keycloak pod: admin credentials and the provider (with its
# secret) go in over stdin, never argv. Lines 1-2: admin login; the rest: JSON.
kc_json() {
  {
    printf '%s\n%s\n' "${admin_username}" "${admin_password}"
    cat
  } |
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

kc() { kc_json "$@" </dev/null; }

# -- 2. Identity provider ------------------------------------------------------------
provider_json() {
  jq -n --arg alias "${alias}" --arg id "${client_id}" --arg secret "${client_secret}" '{
    alias: $alias,
    providerId: "microsoft",
    displayName: "Microsoft",
    enabled: true,
    trustEmail: false,
    storeToken: false,
    addReadTokenRoleOnCreate: false,
    linkOnly: false,
    hideOnLogin: false,
    firstBrokerLoginFlowAlias: "first broker login",
    config: {
      clientId: $id,
      clientSecret: $secret,
      clientAuthMethod: "client_secret_post",
      defaultScope: "openid profile email User.Read",
      syncMode: "IMPORT",
      guiOrder: "1"
    }
  }'
}

if kc get "identity-provider/instances/${alias}" -r "${realm}" >/dev/null 2>&1; then
  provider_json | kc_json update "identity-provider/instances/${alias}" -r "${realm}" -f - >/dev/null
  echo "Updated the Microsoft login in realm ${realm}."
else
  provider_json | kc_json create identity-provider/instances -r "${realm}" -f - >/dev/null
  echo "Added the Microsoft login to realm ${realm}."
fi
unset client_secret

cat <<NEXT

Done. Try it: open Flowloom Studio (dev), sign out, and choose "Microsoft" on
the login page. A new person's account has no Flowloom rights yet: Flowloom
shows them "waiting for approval" (coming with the next engine version).

Renew the secret before it expires in Entra: run this script again.
NEXT
