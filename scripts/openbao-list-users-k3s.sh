#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"

printf "OpenBao root/admin token for k3s target: "
IFS= read -r -s bao_token
printf "\n"

if [[ -z "${bao_token}" ]]; then
  echo "No token entered; aborting." >&2
  exit 1
fi

echo "Auth methods:"
kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${bao_token}" bao auth list

echo
echo "Userpass users:"
kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${bao_token}" bao list auth/userpass/users

for user in admin terraform laptop; do
  echo
  echo "User '${user}' details:"
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_TOKEN=${bao_token}" bao read "auth/userpass/users/${user}" || true
done

