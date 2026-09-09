#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_file="${1:-${repo_root}/ansible/security-vm.ini}"
ssh_key="${SECURITY_VM_ANSIBLE_SSH_KEY:-~/.ssh/hetzner_admin_ed25519}"

security_vm_json="$(cd "${repo_root}/terraform/kvm" && tofu output -json security_vm 2>/dev/null || true)"

if [[ -z "${security_vm_json}" || "${security_vm_json}" == "null" ]]; then
  echo "No KVM security VM found in OpenTofu output. Create it first with tofu -chdir=terraform/kvm apply." >&2
  exit 1
fi

vm_ip="$(jq -r '.addresses[0] // empty' <<<"${security_vm_json}")"
admin_user="$(jq -r '.admin_user // "adm-master"' <<<"${security_vm_json}")"

if [[ -z "${vm_ip}" ]]; then
  echo "The VM has no reported IP address yet. Wait for cloud-init/DHCP, then try again." >&2
  exit 1
fi

{
  echo "[security_vm]"
  echo "security-master ansible_host=${vm_ip} ansible_user=${admin_user} ansible_python_interpreter=/usr/bin/python3"
  echo
  echo "[security_vm:vars]"
  echo "ansible_ssh_private_key_file=${ssh_key}"
} > "${output_file}"

echo "Wrote ${output_file}"
echo "Next:"
echo "  cd ${repo_root}/ansible"
echo "  ansible-playbook -i security-vm.ini playbooks/50-security-vm-bootstrap.yml"
