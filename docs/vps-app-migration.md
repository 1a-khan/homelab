# VPS App Migration

Goal: move the Coolify-hosted VPS apps to the on-prem k3s cluster, then cancel the VPS subscription when every app is proven.

## Current VPS Apps

Collected from `hetzner-prod` on 2026-08-17.

```text
openbao.miak-it.com   OpenBao 2.6.1, migrated to k3s staging already
n8n.miak-it.com       n8n 2.30.8, Postgres 17-alpine, Redis 6-alpine, task runners
windmill.miak-it.com  Windmill 1.764.0, Postgres 17, workers, native worker, LSP
hermes                Hermes webui/agent
kids-prep             custom app, ghcr.io/1a-khan/kids-prep:latest
grafana/monitoring    VPS monitoring stack, likely replaced by local monitoring
```

## Migration Order

1. OpenBao: migrated to k3s and cut over to `openbao.miak-it.com`.
2. n8n: migrated to k3s and cut over to `n8n.miak-it.com`.
3. Windmill: migrate after n8n, preserving `BASE_URL` and database.
4. Custom apps: `kids-prep`, `hermes`, and unknown app `uoow44...`.
5. Decommission duplicated VPS monitoring after local dashboards cover what we need.

## n8n Migration

Status: production cutover completed on 2026-08-18.

Production hostname:

```text
https://n8n.miak-it.com
```

Current target:

```text
Cloudflare proxied CNAME -> 50327130-69c0-4ff9-a8c2-d44d516dd17d.cfargotunnel.com -> k3s Traefik -> n8n namespace
```

Preserve:

```text
N8N_ENCRYPTION_KEY
N8N_RUNNERS_AUTH_TOKEN
N8N_SKIP_AUTH_ON_OAUTH_CALLBACK
Postgres username/password
Postgres database
/home/node/.n8n volume
```

Staging hostname:

```text
https://n8n.miak-it.dev
```

Production hostname after cutover:

```text
https://n8n.miak-it.com
```

Commands:

```bash
cd /home/dev/Desktop/local-svr/homelab
export KUBECONFIG="$PWD/kubeconfig"

kubectl apply -f kubernetes/apps/n8n/namespace.yml
scripts/n8n-export-secrets-to-openbao.sh
kubectl apply -f kubernetes/apps/n8n/external-secret.yml
kubectl get externalsecret -n n8n n8n
kubectl get secret -n n8n n8n

scripts/platform-bootstrap-secrets-openbao.sh
kubectl apply -f kubernetes/platform/postgres/namespace.yml
kubectl apply -f kubernetes/platform/postgres/external-secret.yml
kubectl apply -f kubernetes/platform/postgres/postgres.yml
kubectl apply -f kubernetes/platform/valkey/namespace.yml
kubectl apply -f kubernetes/platform/valkey/external-secret.yml
kubectl apply -f kubernetes/platform/valkey/valkey.yml
kubectl apply -f kubernetes/apps/n8n/n8n.yml
kubectl apply -f kubernetes/apps/n8n/ingress.yml

scripts/n8n-backup-from-vps.sh
scripts/n8n-restore-to-k3s.sh
```

If credentials fail to decrypt after restore, the `.env` value did not match the key in `/home/node/.n8n/config`. Repair OpenBao from the backed-up config:

```bash
scripts/n8n-sync-encryption-key-from-backup.sh
```

After staging verification, do a short maintenance window:

1. Stop/disable n8n writes on the VPS.
2. Take a final DB and volume backup.
3. Restore final backup to k3s.
4. Change `n8n.miak-it.com` from the VPS A record to Cloudflare Tunnel using OpenTofu.
5. Verify webhooks, OAuth redirects, API clients, and Claude/Codex connections.

Before OpenTofu manages the existing production DNS record, import it:

```bash
scripts/iac-import-cloudflare-dns-record.sh \
  cloudflare_dns_record.n8n_prod \
  0c7c24e4a1b41fc6cd480c93bfdfdd99 \
  n8n.miak-it.com
```
