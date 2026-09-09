# Local Security VM

This VM is for local vulnerability and update monitoring experiments:

- Wazuh manager or Wazuh agent testing
- Greenbone/OpenVAS scans
- restic/rclone backup experiments
- local-only admin tools

It is intentionally separate from the public Hetzner VPS plan. A laptop VM sleeps when
the laptop sleeps, so it is not a good external uptime monitor. Keep Uptime Kuma on an
external service or VPS when you need alerts during LTE/router/home outages.

## Shape

Default OpenTofu VM:

```text
name: security-master
OS: Ubuntu 24.04 LTS
CPU: 4 vCPU
RAM: 8 GiB
disk: 120 GiB qcow2 thin-provisioned
network: libvirt default NAT
admin user: adm-master
security user: security-agent
```

The `security-agent` user has SSH login only and no sudo. Use Wazuh agents for real
host telemetry instead of relying only on this user.

## Create

```bash
cd /home/dev/Desktop/local-svr/homelab
tofu -chdir=terraform/kvm init
tofu -chdir=terraform/kvm plan
tofu -chdir=terraform/kvm apply
```

Useful overrides:

```hcl
vm_vcpus      = 4
vm_memory_mib = 8192
vm_disk_bytes = 128849018880
```

After creation:

```bash
scripts/iac-kvm-write-ansible-inventory.sh
cd ansible
ansible-playbook -i security-vm.ini playbooks/50-security-vm-bootstrap.yml
```

Connect:

```bash
tofu -chdir=terraform/kvm output security_vm_ip
ssh adm-master@VM_IP -i ~/.ssh/hetzner_admin_ed25519
```

## Autostart After Boot And Resume

```bash
scripts/kvm-security-vm-install-resume-hook.sh
```

This enables libvirt autostart and installs a systemd sleep hook that starts the VM
after the laptop wakes.

## Direct Script Fallback

The preferred flow is OpenTofu plus Ansible. If the libvirt provider has trouble on
this laptop, `scripts/kvm-security-vm-create.sh` can create the same basic VM with
plain libvirt tools.

## Cloud Cleanup

If the Hetzner VPS plan is paused, remove the partial Hetzner resources created by
OpenTofu:

```bash
scripts/iac-tofu-hetzner.sh destroy \
  -target='hcloud_server.staging["master"]' \
  -target='hcloud_server_network.staging["master"]' \
  -target='hcloud_firewall.master_default[0]' \
  -target='hcloud_network_subnet.private[0]' \
  -target='hcloud_network.private[0]'
```
