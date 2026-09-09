#!/usr/bin/env bash
set -euo pipefail

vm_name="${VM_NAME:-security-master}"
vm_vcpus="${VM_VCPUS:-6}"
vm_memory_mib="${VM_MEMORY_MIB:-12288}"
vm_disk_gb="${VM_DISK_GB:-160}"
vm_network="${VM_NETWORK:-default}"
vm_image_dir="${VM_IMAGE_DIR:-/var/lib/libvirt/images}"
ubuntu_image_url="${UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
admin_user="${VM_ADMIN_USER:-adm-master}"
security_user="${VM_SECURITY_USER:-security-agent}"
ssh_public_key_file="${VM_SSH_PUBLIC_KEY_FILE:-${HOME}/.ssh/hetzner_admin_ed25519.pub}"

work_dir="${HOME}/.cache/homelab-kvm/${vm_name}"
base_image="${work_dir}/ubuntu-24.04-noble-cloudimg-amd64.img"
disk_image="${vm_image_dir}/${vm_name}.qcow2"
seed_image="${vm_image_dir}/${vm_name}-seed.iso"

if [[ ! -r "${ssh_public_key_file}" ]]; then
  echo "SSH public key not found: ${ssh_public_key_file}" >&2
  exit 1
fi

ssh_public_key="$(<"${ssh_public_key_file}")"

if virsh dominfo "${vm_name}" >/dev/null 2>&1; then
  echo "VM '${vm_name}' already exists."
  echo "Use 'virsh start ${vm_name}' or remove it deliberately before recreating."
  exit 0
fi

mkdir -p "${work_dir}"

if [[ ! -f "${base_image}" ]]; then
  echo "Downloading Ubuntu 24.04 LTS cloud image..."
  curl -fL "${ubuntu_image_url}" -o "${base_image}"
fi

echo "Creating VM disk ${disk_image}..."
sudo qemu-img create -f qcow2 -F qcow2 -b "${base_image}" "${disk_image}" "${vm_disk_gb}G" >/dev/null

cat >"${work_dir}/user-data" <<USER_DATA
#cloud-config
hostname: ${vm_name}
manage_etc_hosts: true
timezone: Europe/Berlin

users:
  - default
  - name: ${admin_user}
    gecos: Admin Master
    shell: /bin/bash
    groups: [adm, sudo, docker]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - ${ssh_public_key}
  - name: ${security_user}
    gecos: Security Agent
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${ssh_public_key}

package_update: true
package_upgrade: true
packages:
  - apt-transport-https
  - auditd
  - ca-certificates
  - curl
  - docker.io
  - docker-compose-v2
  - fail2ban
  - git
  - htop
  - jq
  - qemu-guest-agent
  - restic
  - rclone
  - unattended-upgrades
  - ufw
  - vim

write_files:
  - path: /etc/ssh/sshd_config.d/99-homelab-hardening.conf
    permissions: "0644"
    content: |
      PermitRootLogin no
      PasswordAuthentication no
      PubkeyAuthentication yes
      KbdInteractiveAuthentication no
      X11Forwarding no
      AllowUsers ${admin_user} ${security_user}
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    permissions: "0644"
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";

runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl enable --now docker
  - systemctl enable --now fail2ban
  - usermod -aG docker ${admin_user}
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow 22/tcp
  - ufw allow from 192.168.0.0/16
  - ufw --force enable
  - systemctl restart ssh
USER_DATA

cat >"${work_dir}/meta-data" <<META_DATA
instance-id: ${vm_name}
local-hostname: ${vm_name}
META_DATA

echo "Creating cloud-init seed image ${seed_image}..."
sudo cloud-localds "${seed_image}" "${work_dir}/user-data" "${work_dir}/meta-data"

echo "Creating VM '${vm_name}'..."
virt-install \
  --name "${vm_name}" \
  --memory "${vm_memory_mib}" \
  --vcpus "${vm_vcpus}" \
  --cpu host-passthrough \
  --disk "path=${disk_image},format=qcow2,bus=virtio" \
  --disk "path=${seed_image},device=cdrom" \
  --os-variant ubuntu24.04 \
  --import \
  --graphics none \
  --network "network=${vm_network},model=virtio" \
  --noautoconsole

virsh autostart "${vm_name}"

echo "VM '${vm_name}' created and marked for autostart."
echo
echo "Wait 1-2 minutes for cloud-init, then run:"
echo "  virsh domifaddr ${vm_name}"
echo "  ssh ${admin_user}@<vm-ip> -i ${HOME}/.ssh/hetzner_admin_ed25519"
