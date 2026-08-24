#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
namespace="openbao"
pod="openbao-0"
username="iac"
api_base="https://api.hetzner.cloud/v1"
mode="${1:-summary}"

client_token=""
cleanup() {
  if [[ -n "${client_token}" ]]; then
    kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pod}" -- \
      env "BAO_TOKEN=${client_token}" bao token revoke -self >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage: scripts/iac-hetzner-inventory.sh [summary|raw|server-types|cheap]

Modes:
  summary       Human-readable inventory of current project resources.
  raw           Raw JSON for important resource lists.
  server-types  Server type catalog with disk, CPU, RAM, architecture.
  cheap         Cheapest x86 server types by monthly gross price when pricing is available.
USAGE
}

case "${mode}" in
  summary|raw|server-types|cheap) ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

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

hcloud_get() {
  local endpoint="$1"
  curl -fsS \
    -H "Authorization: Bearer ${hcloud_token}" \
    -H "Content-Type: application/json" \
    "${api_base}/${endpoint}"
}

servers_json="$(hcloud_get servers?per_page=50)"
networks_json="$(hcloud_get networks?per_page=50)"
firewalls_json="$(hcloud_get firewalls?per_page=50)"
ssh_keys_json="$(hcloud_get ssh_keys?per_page=50)"
volumes_json="$(hcloud_get volumes?per_page=50)"
load_balancers_json="$(hcloud_get load_balancers?per_page=50)"
server_types_json="$(hcloud_get server_types?per_page=100)"
locations_json="$(hcloud_get locations?per_page=50)"

unset hcloud_token

if [[ "${mode}" == "raw" ]]; then
  jq -n \
    --argjson servers "${servers_json}" \
    --argjson networks "${networks_json}" \
    --argjson firewalls "${firewalls_json}" \
    --argjson ssh_keys "${ssh_keys_json}" \
    --argjson volumes "${volumes_json}" \
    --argjson load_balancers "${load_balancers_json}" \
    --argjson server_types "${server_types_json}" \
    --argjson locations "${locations_json}" \
    '{
      servers: $servers.servers,
      networks: $networks.networks,
      firewalls: $firewalls.firewalls,
      ssh_keys: $ssh_keys.ssh_keys,
      volumes: $volumes.volumes,
      load_balancers: $load_balancers.load_balancers,
      server_types: $server_types.server_types,
      locations: $locations.locations
    }'
  exit 0
fi

if [[ "${mode}" == "server-types" ]]; then
  jq -r '
    def price_for($loc):
      ([.prices[]? | select(.location == $loc) | .price_monthly.gross | tonumber] | min) // "-";
    def germany_locations:
      ([.prices[]?.location | select(. == "nbg1" or . == "fsn1" or . == "hel1")] | unique | join(","));

    ["name","arch","cores","memory_gb","disk_gb","storage_type","nbg1_gross","fsn1_gross","hel1_gross","germany_locations"],
    (.server_types[]
      | [
          .name,
          .architecture,
          (.cores|tostring),
          (.memory|tostring),
          (.disk|tostring),
          .storage_type,
          (price_for("nbg1")|tostring),
          (price_for("fsn1")|tostring),
          (price_for("hel1")|tostring),
          germany_locations
        ])
    | @tsv
  ' <<<"${server_types_json}" | column -t -s $'\t'
  exit 0
fi

if [[ "${mode}" == "cheap" ]]; then
  jq -r '
    def germany_prices:
      [.prices[]? | select(.location == "nbg1" or .location == "fsn1" or .location == "hel1") | .price_monthly.gross | tonumber];
    def germany_locations:
      ([.prices[]?.location | select(. == "nbg1" or . == "fsn1" or . == "hel1")] | unique | join(","));

    ["name","arch","cores","memory_gb","disk_gb","germany_monthly_gross_from","germany_locations"],
    ([.server_types[]
      | select(.architecture == "x86")
      | {
          name,
          architecture,
          cores,
          memory,
          disk,
          monthly: (germany_prices | min),
          germany_locations: germany_locations
        }
      | select(.monthly != null)]
      | sort_by(.monthly)
      | .[:15][]
      | [.name, .architecture, (.cores|tostring), (.memory|tostring), (.disk|tostring), (.monthly|tostring), .germany_locations])
    | @tsv
  ' <<<"${server_types_json}" | column -t -s $'\t'
  exit 0
fi

echo "== Servers =="
jq -r '
  if (.servers | length) == 0 then
    "none"
  else
    ["name","id","status","type","image","datacenter","ipv4","ipv6","labels"],
    (.servers[]
      | [
          .name,
          (.id|tostring),
          .status,
          .server_type.name,
          .image.name,
          .datacenter.name,
          (.public_net.ipv4.ip // "-"),
          (.public_net.ipv6.ip // "-"),
          (.labels // {} | to_entries | map("\(.key)=\(.value)") | join(","))
        ])
    | @tsv
  end
' <<<"${servers_json}" | column -t -s $'\t'

echo
echo "== Networks =="
jq -r '
  if (.networks | length) == 0 then
    "none"
  else
    ["name","id","ip_range","subnets","routes","servers"],
    (.networks[]
      | [
          .name,
          (.id|tostring),
          .ip_range,
          (.subnets | map("\(.type):\(.ip_range):\(.network_zone):gw=\(.gateway)") | join(",")),
          (.routes | length | tostring),
          (.servers | map(tostring) | join(","))
        ])
    | @tsv
  end
' <<<"${networks_json}" | column -t -s $'\t'

echo
echo "== Firewalls =="
jq -r '
  if (.firewalls | length) == 0 then
    "none"
  else
    ["name","id","rules","applied_to"],
    (.firewalls[]
      | [
          .name,
          (.id|tostring),
          (.rules | length | tostring),
          (.applied_to | length | tostring)
        ])
    | @tsv
  end
' <<<"${firewalls_json}" | column -t -s $'\t'

echo
echo "== SSH Keys =="
jq -r '
  if (.ssh_keys | length) == 0 then
    "none"
  else
    ["name","id","fingerprint","labels"],
    (.ssh_keys[]
      | [
          .name,
          (.id|tostring),
          .fingerprint,
          (.labels // {} | to_entries | map("\(.key)=\(.value)") | join(","))
        ])
    | @tsv
  end
' <<<"${ssh_keys_json}" | column -t -s $'\t'

echo
echo "== Volumes =="
jq -r '
  if (.volumes | length) == 0 then
    "none"
  else
    ["name","id","size_gb","location","server","linux_device"],
    (.volumes[]
      | [
          .name,
          (.id|tostring),
          (.size|tostring),
          .location.name,
          ((.server // "-") | tostring),
          (.linux_device // "-")
        ])
    | @tsv
  end
' <<<"${volumes_json}" | column -t -s $'\t'

echo
echo "== Load Balancers =="
jq -r '
  if (.load_balancers | length) == 0 then
    "none"
  else
    ["name","id","type","location","ipv4","ipv6"],
    (.load_balancers[]
      | [
          .name,
          (.id|tostring),
          .load_balancer_type.name,
          .location.name,
          (.public_net.ipv4.ip // "-"),
          (.public_net.ipv6.ip // "-")
        ])
    | @tsv
  end
' <<<"${load_balancers_json}" | column -t -s $'\t'

echo
echo "== Cheapest x86 Server Types =="
jq -r '
  def germany_prices:
    [.prices[]? | select(.location == "nbg1" or .location == "fsn1" or .location == "hel1") | .price_monthly.gross | tonumber];
  def germany_locations:
    ([.prices[]?.location | select(. == "nbg1" or . == "fsn1" or . == "hel1")] | unique | join(","));

  ["name","cores","memory_gb","disk_gb","germany_monthly_gross_from","germany_locations"],
  ([.server_types[]
    | select(.architecture == "x86")
    | {
        name,
        cores,
        memory,
        disk,
        monthly: (germany_prices | min),
        germany_locations: germany_locations
      }
    | select(.monthly != null)]
    | sort_by(.monthly)
    | .[:10][]
    | [.name, (.cores|tostring), (.memory|tostring), (.disk|tostring), (.monthly|tostring), .germany_locations])
  | @tsv
' <<<"${server_types_json}" | column -t -s $'\t'
