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

## Lookup Existing Server

Copy the example vars:

```bash
cp terraform/hetzner/terraform.tfvars.example terraform/hetzner/terraform.tfvars
```

Edit:

```hcl
lookup_server_name = "dev-prod-16gb-nbg1"
```

Then:

```bash
scripts/iac-tofu-hetzner.sh plan
scripts/iac-tofu-hetzner.sh output lookup_server
```

This should show the existing server ID, type, IP, datacenter, and status.

## Import Existing Server

After the lookup tells us the real server ID, add a matching entry:

```hcl
managed_servers = {
  prod = {
    name        = "dev-prod-16gb-nbg1"
    server_type = "cx42"
    image       = "ubuntu-24.04"
    location    = "nbg1"
    ssh_keys    = ["coolifyy key"]
    backups     = false
    labels = {
      role        = "legacy-vps"
      environment = "prod"
    }
  }
}
```

Then import:

```bash
scripts/iac-tofu-hetzner.sh import 'hcloud_server.servers["prod"]' <server-id>
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
