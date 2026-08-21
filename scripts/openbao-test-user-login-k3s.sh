#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"

username="${1:-}"
if [[ -z "${username}" ]]; then
  printf "OpenBao username: "
  IFS= read -r username
fi

if [[ -z "${username}" ]]; then
  echo "No username entered; aborting." >&2
  exit 1
fi

printf "Password for OpenBao user '${username}': "
IFS= read -r -s password
printf "\n"

if [[ -z "${password}" ]]; then
  echo "No password entered; aborting." >&2
  exit 1
fi

login_json="$(
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_LOGIN_USER=${username}" "BAO_LOGIN_PASSWORD=${password}" \
    sh -lc 'bao login -method=userpass -format=json username="$BAO_LOGIN_USER" password="$BAO_LOGIN_PASSWORD"'
)"

client_token="$(jq -r '.auth.client_token // empty' <<<"${login_json}")"

if [[ -z "${client_token}" ]]; then
  echo "Login failed or no client token returned." >&2
  exit 1
fi

echo "Login OK for '${username}'. Token lookup:"
kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${client_token}" bao token lookup

echo
echo "Revoking test token."
kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${client_token}" bao token revoke -self

