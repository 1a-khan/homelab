#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
backup_dir="${repo_root}/backups/openbao"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

snapshot="${1:-}"
if [[ -z "${snapshot}" ]]; then
  snapshot="$(ls -t "${backup_dir}"/openbao-raft-*.snap 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "${snapshot}" || ! -f "${snapshot}" ]]; then
  echo "No snapshot found. Pass a snapshot path or create one first." >&2
  exit 1
fi

chmod 700 "${backup_dir}"

echo "Using snapshot: ${snapshot}"
kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" get pod "${pod}" >/dev/null

init_status=0
kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  bao operator init -status >/tmp/openbao-target-init-status.txt 2>&1 || init_status=$?

case "${init_status}" in
  0)
    echo "Target is already initialized."
    ;;
  2)
    init_file="${backup_dir}/target-temp-init-${timestamp}.json"
    echo "Initializing temporary target cluster. Saving temporary keys to ${init_file}"
    kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
      sh -lc "bao operator init -key-shares=5 -key-threshold=3 -format=json > /tmp/target-temp-init.json"
    kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" cp \
      "${pod}:/tmp/target-temp-init.json" "${init_file}"
    kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
      rm -f /tmp/target-temp-init.json >/dev/null
    chmod 600 "${init_file}"

    for index in 0 1 2; do
      key="$(jq -r "(.unseal_keys_b64 // .keys_base64)[${index}]" "${init_file}")"
      if [[ -z "${key}" || "${key}" == "null" ]]; then
        echo "Could not read unseal key ${index} from ${init_file}" >&2
        exit 1
      fi
      kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
        bao operator unseal "${key}" >/dev/null
    done
    ;;
  *)
    cat /tmp/openbao-target-init-status.txt >&2
    exit "${init_status}"
    ;;
esac

root_token=""
if [[ -n "${init_file:-}" ]]; then
  root_token="$(jq -r ".root_token // .initial_root_token" "${init_file}")"
else
  echo "Target was already initialized. Enter a target OpenBao root/admin token for restore:"
  IFS= read -r -s root_token
  echo
fi

if [[ -z "${root_token}" || "${root_token}" == "null" ]]; then
  echo "No target token available; aborting." >&2
  exit 1
fi

base_snapshot="$(basename "${snapshot}")"
kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" cp "${snapshot}" "${pod}:/tmp/${base_snapshot}"

echo "Restoring snapshot into k3s OpenBao."
kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
  env "BAO_TOKEN=${root_token}" bao operator raft snapshot restore -force "/tmp/${base_snapshot}"

kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- rm -f "/tmp/${base_snapshot}" || true

echo
echo "Restore command completed. The restored OpenBao normally uses the original source unseal keys."
echo "Check status with:"
echo "kubectl --kubeconfig ${kubeconfig} -n ${namespace} exec ${pod} -- bao status || true"
