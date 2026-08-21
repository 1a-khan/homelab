#!/usr/bin/env bash

openbao_login_userpass() {
  local default_username="${1:-admin}"
  local username
  local password
  local login_json

  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for OpenBao login." >&2
    exit 1
  fi

  printf "OpenBao admin username [%s]: " "${default_username}"
  IFS= read -r username
  username="${username:-${default_username}}"

  if [[ -z "${username}" ]]; then
    echo "No OpenBao username entered; aborting." >&2
    exit 1
  fi

  printf "Password for OpenBao user '%s': " "${username}"
  IFS= read -r -s password
  printf "\n"

  if [[ -z "${password}" ]]; then
    echo "No OpenBao password entered; aborting." >&2
    exit 1
  fi

  login_json="$(
    kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
      env "BAO_LOGIN_USER=${username}" "BAO_LOGIN_PASSWORD=${password}" \
      sh -lc 'bao login -method=userpass -format=json username="${BAO_LOGIN_USER}" password="${BAO_LOGIN_PASSWORD}"'
  )"
  unset password

  BAO_TOKEN="$(jq -r '.auth.client_token // empty' <<<"${login_json}")"
  export BAO_TOKEN

  if [[ -z "${BAO_TOKEN}" ]]; then
    echo "OpenBao login failed or no token returned." >&2
    exit 1
  fi
}

openbao_revoke_login_token() {
  if [[ -n "${BAO_TOKEN:-}" ]]; then
    kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
      env "BAO_TOKEN=${BAO_TOKEN}" bao token revoke -self >/dev/null 2>&1 || true
  fi
}

openbao_login_admin() {
  openbao_login_userpass "${1:-admin}"
  trap openbao_revoke_login_token EXIT
}
