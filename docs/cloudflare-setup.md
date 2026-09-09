# Cloudflare Setup

Goal: expose only `hello.miak-it.dev` through Cloudflare Tunnel to the k3s cluster.

This does not change `maik-it.com` or `www.maik-it.com`, so the existing VPS website can keep working.

## 1. Confirm Domain Is In Cloudflare

Open Cloudflare Dashboard:

```text
Websites -> miak-it.dev
```

If `miak-it.dev` is not listed, add it to Cloudflare first and follow Cloudflare's nameserver instructions at your domain registrar.

## 2. Get Account ID And Zone ID

Open:

```text
Websites -> miak-it.dev -> Overview
```

Copy:

```text
Account ID
Zone ID
```

You will put these into:

```text
terraform/cloudflare/terraform.tfvars
```

## 3. Create API Token

Open:

```text
My Profile -> API Tokens -> Create Token -> Create Custom Token
```

Use a name like:

```text
homelab-opentofu-cloudflare
```

Required permissions:

```text
Account -> Cloudflare Tunnel -> Edit
Account -> Access: Apps and Policies -> Edit
Account -> Access: Organizations, Identity Providers, and Groups -> Edit
Zone    -> DNS -> Edit
```

Scope it as tightly as possible:

```text
Account Resources -> your Cloudflare account
Zone Resources    -> miak-it.dev and miak-it.com

Account permissions:
- Cloudflare Tunnel:Edit
- Access: Apps and Policies:Edit
- Access: Organizations, Identity Providers, and Groups:Edit

Zone permissions:
- DNS:Edit
```

Copy the token once. Do not paste it into chat.

## 4. Store Cloudflare Token In OpenBao

Store the Cloudflare token in OpenBao and create a dedicated `iac` OpenBao user:

```bash
cd /home/dev/Desktop/local-svr/homelab
scripts/iac-bootstrap-cloudflare-openbao.sh
```

The script asks silently for:

```text
OpenBao admin username and password
Cloudflare API token
New password for OpenBao user iac
```

The Cloudflare token is stored at:

```text
apps/iac/cloudflare
```

## 5. Create Local OpenTofu Variables

From the repo root:

```bash
cp terraform/cloudflare/terraform.tfvars.example terraform/cloudflare/terraform.tfvars
nano terraform/cloudflare/terraform.tfvars
```

Set:

```hcl
cloudflare_account_id = "PASTE_ACCOUNT_ID_HERE"
cloudflare_zone_id    = "PASTE_ZONE_ID_HERE"
cloudflare_zone_name  = "miak-it.dev"
hello_hostname        = "hello"
access_allowed_email  = "operator@example.com"
```

Do not commit `terraform.tfvars`.

## 6. Run OpenTofu With OpenBao Secret Retrieval

Run OpenTofu through the wrapper so the Cloudflare token is fetched from OpenBao at runtime and never stored in `terraform.tfvars`:

```bash
cd /home/dev/Desktop/local-svr/homelab/terraform/cloudflare
../../scripts/iac-tofu-cloudflare.sh plan
../../scripts/iac-tofu-cloudflare.sh apply
```

This protects:

```text
https://hello.miak-it.dev
```

with an allow policy for:

```text
operator@example.com
```

The config also creates a One-time PIN identity provider and attaches it to the app, so users can log in by email code instead of Cloudflare account password.
