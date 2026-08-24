#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_key="${1:-}"

if [[ -z "${target_key}" ]]; then
  echo "Usage: scripts/iac-hetzner-staging-destroy.sh <staging_server_key>" >&2
  echo "Example: scripts/iac-hetzner-staging-destroy.sh app_test" >&2
  exit 1
fi

echo "This will destroy only terraform/hetzner hcloud_server.staging[\"${target_key}\"] and its attached staging network resource."
echo "It will NOT destroy imported protected production servers."
printf "Type destroy-%s to continue: " "${target_key}"
IFS= read -r confirmation

if [[ "${confirmation}" != "destroy-${target_key}" ]]; then
  echo "Confirmation did not match; aborting."
  exit 1
fi

"${repo_root}/scripts/iac-tofu-hetzner.sh" destroy \
  -target="hcloud_server_network.staging[\"${target_key}\"]" \
  -target="hcloud_server.staging[\"${target_key}\"]"
