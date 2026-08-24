# Hetzner OpenTofu

Goal: manage Hetzner Cloud infrastructure with OpenTofu while keeping API tokens in OpenBao.

## Safety Model

For existing production VPS servers, do this in stages:

1. Store the Hetzner API token in OpenBao.
2. Use data-source lookup to inspect existing servers.
3. Add an explicit `managed_servers` entry only after we know the exact server type, image, location, SSH keys, and labels.
4. Import the existing server into state.
5. Run `plan`.
6. Apply only if the plan does not recreate or unexpectedly modify the VPS.

The managed server resource has:

```text
prevent_destroy = true
delete_protection = true
rebuild_protection = true
```

This is intentional. Production infrastructure should be annoying to destroy.

## Store Hetzner Token

Run from the homelab repo:

```bash
cd /home/dev/Desktop/local-svr/homelab
export KUBECONFIG="$PWD/kubeconfig"
scripts/iac-bootstrap-hetzner-openbao.sh
```

The script asks for:

```text
OpenBao admin username/password
Hetzner Cloud API token
iac user password
```

The token is stored at:

```text
apps/iac/hetzner
```

OpenTofu receives it as:

```text
TF_VAR_hcloud_token
```

## Initialize

```bash
scripts/iac-tofu-hetzner.sh init
```

## Inventory Current Project

Before importing or creating anything, list what the Hetzner project currently has:

```bash
scripts/iac-hetzner-inventory.sh
```

This lists:

```text
servers
networks
firewalls
SSH keys
volumes
load balancers
cheapest x86 server types
```

For raw JSON:

```bash
scripts/iac-hetzner-inventory.sh raw
```

For all server types:

```bash
scripts/iac-hetzner-inventory.sh server-types
```

For cheap x86 options sorted by monthly gross price:

```bash
scripts/iac-hetzner-inventory.sh cheap
```

Use this before creating a new VPS. It shows the current project inventory and the currently available server sizes/prices returned by the Hetzner API.

## Lookup Existing Server

Copy the example vars:

```bash
cp terraform/hetzner/terraform.tfvars.example terraform/hetzner/terraform.tfvars
```

Edit:

```hcl
lookup_server_names = [
  "dev-prod-16gb-nbg1",
  "coolify-ubuntu-4gb-nbg1-1",
]
```

Then:

```bash
scripts/iac-tofu-hetzner.sh plan
scripts/iac-tofu-hetzner.sh output lookup_servers
```

This should show the existing server IDs, types, IPs, datacenters, and status. `terraform.tfvars` should contain only non-secret names and configuration. The Hetzner token stays in OpenBao.

## Import Existing Server

After the lookup tells us the real server ID, add a matching entry:

```hcl
managed_servers = {
  prod_16gb = {
    name        = "dev-prod-16gb-nbg1"
    server_type = "cx43"
    image       = "ubuntu-24.04"
    location    = "nbg1"
    ssh_keys    = ["coolifyy key"]
    backups     = false
    labels = {
      role        = "legacy-vps"
      environment = "prod"
    }
  }

  coolify_4gb = {
    name        = "coolify-ubuntu-4gb-nbg1-1"
    server_type = "cx23"
    image       = "ubuntu-24.04"
    location    = "nbg1"
    ssh_keys    = ["coolifyy key"]
    backups     = false
    labels = {
      role        = "edge-vps"
      environment = "prod"
    }
  }
}
```

Then import:

```bash
scripts/iac-tofu-hetzner.sh import 'hcloud_server.servers["prod_16gb"]' <server-id>
scripts/iac-tofu-hetzner.sh import 'hcloud_server.servers["coolify_4gb"]' <server-id>
```

Now run:

```bash
scripts/iac-tofu-hetzner.sh plan
```

Expected for a clean import:

```text
No changes
```

Small label/protection changes may be acceptable. A destroy/recreate is not acceptable.

## Later

After imports are clean, we can add:

```text
firewalls
small 4 GB VPS
load balancer or reverse proxy
snapshots/backups
private network between Hetzner servers
monitoring labels/cost metadata
```
