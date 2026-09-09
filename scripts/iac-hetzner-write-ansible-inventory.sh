#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_file="${1:-${repo_root}/ansible/hetzner-staging.ini}"
ssh_key="${HETZNER_ANSIBLE_SSH_KEY:-~/.ssh/hetzner_admin_ed25519}"

mkdir -p "$(dirname "${output_file}")"

staging_json="$(cd "${repo_root}/terraform/hetzner" && tofu output -json staging_servers 2>/dev/null || true)"

if [[ -z "${staging_json}" || "${staging_json}" == "null" || "${staging_json}" == "{}" ]]; then
  echo "No staging servers found in OpenTofu output. Create one first with scripts/iac-tofu-hetzner.sh apply." >&2
  exit 1
fi

{
  echo "[hetzner_vps]"
  jq -r '
    to_entries[]
    | select(.value.ipv4 != null and .value.ipv4 != "")
    | "\(.key) ansible_host=\(.value.ipv4) ansible_user=root ansible_python_interpreter=/usr/bin/python3"
  ' <<<"${staging_json}"
  echo
  echo "[hetzner_vps:vars]"
  echo "ansible_ssh_private_key_file=${ssh_key}"
} > "${output_file}"

echo "Wrote ${output_file}"
echo "Next:"
echo "  cd ${repo_root}/ansible"
echo "  ansible-playbook -i hetzner-staging.ini playbooks/30-hetzner-vps-bootstrap.yml"
