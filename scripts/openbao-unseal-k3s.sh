#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"

for index in 1 2 3; do
  printf "Original VPS OpenBao unseal key %s: " "${index}"
  IFS= read -r -s unseal_key
  printf "\n"

  if [[ -z "${unseal_key}" ]]; then
    echo "No key entered; aborting." >&2
    exit 1
  fi

  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    bao operator unseal "${unseal_key}"
done

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- bao status
