#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
username="iac"
api_base="https://api.hetzner.cloud/v1"

declare -A old_networks=(
  [11887785]="coolify-net"
)

declare -A old_firewalls=(
  [11340959]="FW-coolify-ubuntu-4gb-nbg1-1"
  [11370851]="FW-big-cat-vps"
)

declare -A old_volumes=(
  [104518065]="volume-nbg1-1"
)

declare -A old_ssh_keys=(
  [106340300]="coolify-hetzner"
  [107529459]="ammadkhan@msn.com"
)

echo "This will permanently delete old unattached Hetzner resources:"
echo
echo "Networks:"
for id in "${!old_networks[@]}"; do echo "  ${id} ${old_networks[${id}]}"; done
echo "Firewalls:"
for id in "${!old_firewalls[@]}"; do echo "  ${id} ${old_firewalls[${id}]}"; done
echo "Volumes:"
for id in "${!old_volumes[@]}"; do echo "  ${id} ${old_volumes[${id}]}"; done
echo "SSH keys:"
for id in "${!old_ssh_keys[@]}"; do echo "  ${id} ${old_ssh_keys[${id}]}"; done
echo
echo "The miak-hetzner-admin SSH key is intentionally preserved."
printf "Type clean-hetzner-orphans to continue: "
IFS= read -r confirmation

if [[ "${confirmation}" != "clean-hetzner-orphans" ]]; then
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

  curl -fsS -X "${method}" \
    -H "Authorization: Bearer ${hcloud_token}" \
    -H "Content-Type: application/json" \
    "${api_base}/${endpoint}"
}

verify_name() {
  local endpoint="$1"
  local jq_path="$2"
  local id="$3"
  local expected_name="$4"
  local actual_name

  actual_name="$(hcloud_request GET "${endpoint}/${id}" | jq -r "${jq_path} // empty")"
  if [[ "${actual_name}" != "${expected_name}" ]]; then
    echo "${endpoint}/${id} name mismatch: expected '${expected_name}', got '${actual_name}'." >&2
    exit 1
  fi
}

for id in "${!old_networks[@]}"; do verify_name networks '.network.name' "${id}" "${old_networks[${id}]}"; done
for id in "${!old_firewalls[@]}"; do verify_name firewalls '.firewall.name' "${id}" "${old_firewalls[${id}]}"; done
for id in "${!old_volumes[@]}"; do verify_name volumes '.volume.name' "${id}" "${old_volumes[${id}]}"; done
for id in "${!old_ssh_keys[@]}"; do verify_name ssh_keys '.ssh_key.name' "${id}" "${old_ssh_keys[${id}]}"; done

for id in "${!old_volumes[@]}"; do
  echo "Deleting volume ${id} ${old_volumes[${id}]}..."
  hcloud_request DELETE "volumes/${id}" >/dev/null
done

for id in "${!old_firewalls[@]}"; do
  echo "Deleting firewall ${id} ${old_firewalls[${id}]}..."
  hcloud_request DELETE "firewalls/${id}" >/dev/null
done

for id in "${!old_ssh_keys[@]}"; do
  echo "Deleting SSH key ${id} ${old_ssh_keys[${id}]}..."
  hcloud_request DELETE "ssh_keys/${id}" >/dev/null
done

for id in "${!old_networks[@]}"; do
  echo "Deleting network ${id} ${old_networks[${id}]}..."
  hcloud_request DELETE "networks/${id}" >/dev/null
done

unset hcloud_token

echo "Cleanup requests submitted. Run scripts/iac-hetzner-inventory.sh to confirm."
