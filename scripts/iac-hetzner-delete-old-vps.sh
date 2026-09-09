#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
username="iac"
api_base="https://api.hetzner.cloud/v1"

declare -A expected_servers=(
  [119009181]="coolify-ubuntu-4gb-nbg1-1"
  [141051456]="dev-prod-16gb-nbg1"
)

echo "This will permanently delete these Hetzner Cloud servers:"
for server_id in "${!expected_servers[@]}"; do
  echo "  ${server_id} ${expected_servers[${server_id}]}"
done
echo
echo "This is not an OpenTofu destroy. These existing servers are not in Hetzner state."
printf "Type delete-old-vps to continue: "
IFS= read -r confirmation

if [[ "${confirmation}" != "delete-old-vps" ]]; then
  echo "Confirmation did not match; aborting."
  exit 1
fi

client_token=""
cleanup() {
  if [[ -n "${client_token}" ]]; then
    kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
      env "BAO_TOKEN=${client_token}" bao token revoke -self >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

printf "Password for OpenBao user '%s': " "${username}"
IFS= read -r -s iac_password
printf "\n"

if [[ -z "${iac_password}" ]]; then
  echo "No password entered; aborting." >&2
  exit 1
fi

login_json="$(
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_LOGIN_USER=${username}" "BAO_LOGIN_PASSWORD=${iac_password}" \
    sh -lc 'bao login -method=userpass -format=json username="${BAO_LOGIN_USER}" password="${BAO_LOGIN_PASSWORD}"'
)"
unset iac_password

client_token="$(jq -r '.auth.client_token // empty' <<<"${login_json}")"

if [[ -z "${client_token}" ]]; then
  echo "OpenBao login failed or no token returned." >&2
  exit 1
fi

hcloud_token="$(
  kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
    env "BAO_TOKEN=${client_token}" \
    bao kv get -field=HCLOUD_TOKEN apps/iac/hetzner
)"

if [[ -z "${hcloud_token}" ]]; then
  echo "Hetzner Cloud API token was not found in OpenBao." >&2
  exit 1
fi

hcloud_request() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  if [[ -n "${data}" ]]; then
    curl -fsS -X "${method}" \
      -H "Authorization: Bearer ${hcloud_token}" \
      -H "Content-Type: application/json" \
      -d "${data}" \
      "${api_base}/${endpoint}"
  else
    curl -fsS -X "${method}" \
      -H "Authorization: Bearer ${hcloud_token}" \
      -H "Content-Type: application/json" \
      "${api_base}/${endpoint}"
  fi
}

for server_id in "${!expected_servers[@]}"; do
  expected_name="${expected_servers[${server_id}]}"
  server_json="$(hcloud_request GET "servers/${server_id}")"
  actual_name="$(jq -r '.server.name // empty' <<<"${server_json}")"

  if [[ "${actual_name}" != "${expected_name}" ]]; then
    echo "Server ${server_id} name mismatch: expected '${expected_name}', got '${actual_name}'." >&2
    echo "Aborting without deleting anything else." >&2
    exit 1
  fi
done

for server_id in "${!expected_servers[@]}"; do
  echo "Disabling delete protection for ${server_id} ${expected_servers[${server_id}]} if needed..."
  hcloud_request POST "servers/${server_id}/actions/change_protection" '{"delete":false,"rebuild":false}' >/dev/null
done

for server_id in "${!expected_servers[@]}"; do
  echo "Deleting ${server_id} ${expected_servers[${server_id}]}..."
  hcloud_request DELETE "servers/${server_id}" >/dev/null
done

unset hcloud_token

echo "Delete requests submitted. Run scripts/iac-hetzner-inventory.sh to confirm they are gone."
