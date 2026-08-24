# Hetzner Staging VPS Factory

This setup creates short-lived Hetzner VPS instances with OpenTofu, hardens them with Ansible, and keeps the Hetzner API token in OpenBao.

## Lifecycle

1. Choose a cheap server type:

   ```bash
   cd /home/dev/Desktop/local-svr/homelab
   scripts/iac-hetzner-inventory.sh cheap
   ```

2. Add one entry to `terraform/hetzner/terraform.tfvars`:

   ```hcl
   staging_allowed_ssh_cidrs = [
     "YOUR_PUBLIC_IP/32",
   ]

   staging_servers = {
     app_test = {
       name        = "staging-app-test-01"
       server_type = "cx23"
       image       = "ubuntu-24.04"
       location    = "nbg1"
       ssh_keys    = ["miak-hetzner-admin"]
       network_id  = 11887785
       labels = {
         purpose = "application-staging"
         ttl     = "delete-after-testing"
       }
     }
   }
   ```

3. Create the VPS:

   ```bash
   scripts/iac-tofu-hetzner.sh plan
   scripts/iac-tofu-hetzner.sh apply
   ```

4. Generate a local Ansible inventory:

   ```bash
   scripts/iac-hetzner-write-ansible-inventory.sh
   ```

5. Copy the example vars once and add your laptop SSH public key:

   ```bash
   cp ansible/group_vars/hetzner_vps.example.yml ansible/group_vars/hetzner_vps.yml
   nano ansible/group_vars/hetzner_vps.yml
   ```

6. Harden the server:

   ```bash
   cd ansible
   ansible-playbook -i hetzner-staging.ini playbooks/30-hetzner-vps-bootstrap.yml
   ```

After the first Ansible run, root SSH and password SSH are disabled. Use the admin user:

```bash
ssh dev_prod@SERVER_PUBLIC_IP
```

## What The Bootstrap Does

- Creates the `dev_prod` admin user.
- Installs your SSH key.
- Disables root SSH login and password login.
- Enables UFW, fail2ban, unattended upgrades, auditd, and qemu guest agent.
- Installs Docker and Docker Compose v2.
- Installs `prometheus-node-exporter` without opening port `9100` publicly.

## Monitoring Path

For now, new staging VPS instances are labeled in Hetzner and get node_exporter installed. Do not expose node_exporter to the public internet.

The production-grade next step is a private monitoring path:

- WireGuard between Hetzner VPS and the homelab, or
- Grafana Alloy on the VPS pushing metrics/logs to a secured homelab endpoint.

Then the homelab Grafana dashboards can show CPU, RAM, disk, updates, security bans, and monthly projected cost.

## Destroy A Staging VPS

Use the helper so you only destroy the staging server you name:

```bash
cd /home/dev/Desktop/local-svr/homelab
scripts/iac-hetzner-staging-destroy.sh app_test
```

This script targets only `hcloud_server.staging["app_test"]` and its network attachment. Imported production servers stay protected by `prevent_destroy`.

## Should We Destroy The Old VPS Now?

Not immediately. The safer path is:

1. Keep both old VPS instances running while DNS has just been moved.
2. Verify for 24 to 48 hours:
   - `n8n.miak-it.com`
   - `windmill.miak-it.com`
   - `kids-prep.miak-it.com`
   - `openbao.miak-it.com`
   - `miak-it.de`
   - mail for `support@miak-it.de`
3. Stop the old app containers on the old 16 GB VPS, but do not delete the server yet.
4. Test webhooks, redirects, agent access, and OpenBao login again.
5. Take final exports or snapshots if needed.
6. Delete the old 16 GB VPS after the rollback window.

The 4 GB VPS can stay as a future edge/staging box. The 16 GB VPS is the best candidate to delete once we are confident, because it is now mostly replaced by the on-prem k3s server.
