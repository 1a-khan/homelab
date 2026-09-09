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
3. Windmill: migrated to k3s and cut over to `windmill.miak-it.com`.
4. Kids-prep: migrated to k3s and cut over to `kids-prep.miak-it.com`.
5. MIAK website: prepared for k3s migration from `phx-miak-website`.
6. Decommission duplicated VPS monitoring after local dashboards cover what we need.

Do not migrate `hermes`; it is no longer needed.

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

## Windmill Migration

Status: prepared, not cut over yet.

Production hostname:

```text
https://windmill.miak-it.com
```

Current VPS source:

```text
Coolify service ID: ngck8kk48wcgoc44kos444w8
Windmill image: ghcr.io/windmill-labs/windmill:1.764.0
Database container: db-ngck8kk48wcgoc44kos444w8
Database volume: ngck8kk48wcgoc44kos444w8_db-data
Database name on VPS: windmill-db
```

Target design:

```text
k3s namespace: windmill
Postgres: shared postgres.database.svc.cluster.local
Target database: windmill
Secrets: OpenBao apps/windmill -> ExternalSecret windmill
Ingress: windmill.miak-it.com -> windmill service
```

Important: do not deploy a separate Windmill Postgres container locally. Windmill must use the unified platform Postgres server.

Backup first:

```bash
cd /home/dev/Desktop/local-svr/homelab
scripts/windmill-backup-from-vps.sh
```

Copy current Windmill database credentials from Coolify into OpenBao:

```bash
scripts/windmill-export-secrets-to-openbao.sh
```

Prepare the Kubernetes target:

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl apply -f kubernetes/apps/windmill/namespace.yml
kubectl apply -f kubernetes/apps/windmill/external-secret.yml
kubectl get externalsecret -n windmill windmill
kubectl get secret -n windmill windmill
```

Restore the Windmill dump into the shared Postgres server:

```bash
scripts/windmill-restore-to-k3s.sh
```

Deploy Windmill app components:

```bash
kubectl apply -f kubernetes/apps/windmill/windmill.yml
kubectl apply -f kubernetes/apps/windmill/ingress.yml
kubectl get pods -n windmill
kubectl get ingress -n windmill
```

Before OpenTofu manages the existing production DNS record, import it:

```bash
scripts/iac-import-cloudflare-dns-record.sh \
  cloudflare_dns_record.windmill_prod \
  <cloudflare_record_id> \
  windmill.miak-it.com
```

Cut over production DNS only after the local app is healthy:

```bash
scripts/iac-tofu-cloudflare.sh plan
scripts/iac-tofu-cloudflare.sh apply
```

Expected DNS change:

```text
windmill.miak-it.com
old: A 203.0.113.10
new: CNAME 50327130-69c0-4ff9-a8c2-d44d516dd17d.cfargotunnel.com
```

## Kids-prep Migration

Status: production cutover completed on 2026-08-21.

Production hostname:

```text
https://kids-prep.miak-it.com
```

Current target:

```text
Cloudflare proxied CNAME -> 50327130-69c0-4ff9-a8c2-d44d516dd17d.cfargotunnel.com -> k3s Traefik -> kids-prep namespace
```

VPS source:

```text
Container: kids-prep-tnsrh6m8fme22otryvwtzfdv-190624758249
Image: ghcr.io/1a-khan/kids-prep:latest
Volume: tnsrh6m8fme22otryvwtzfdv_kids-prep-data -> /app/data
Database: /app/data/kids_prep_prod.db
```

Backup archive verified:

```text
backups/kids-prep/kids-prep-data-20260821T120924Z.tgz
backups/kids-prep/kids-prep-20260821T120924Z.sha256
```

Target design:

```text
k3s namespace: kids-prep
Persistent volume: kids-prep-data
Secrets: OpenBao apps/kids-prep -> ExternalSecret kids-prep
Ingress: kids-prep.miak-it.com -> kids-prep service
```

Restore command:

```bash
cd /home/dev/Desktop/local-svr/homelab
export KUBECONFIG="$PWD/kubeconfig"
scripts/kids-prep-restore-to-k3s.sh backups/kids-prep/kids-prep-data-20260821T120924Z.tgz
```

After restore, run the app migration once if the restored SQLite database is older than the current image:

```bash
kubectl -n kids-prep exec deployment/kids-prep -- /app/bin/migrate
kubectl -n kids-prep rollout restart deployment/kids-prep
```

Note: historical Notion sync records may contain text that exceeds Notion rich text limits. That warning is application data cleanup, not a Kubernetes migration blocker.

## MIAK Website Migration

Status: prepared for k3s cutover.

Production hostnames:

```text
https://miak-it.de
https://www.miak-it.de
```

VPS source:

```text
Container: uoow44sg0w4w4gcko8ok88o0-001131891985
Coolify name: phx-miak-website
Port: 4000
Image commit: cf68f4d37b5750154c115b02cd2b2c91bd838f8c
Persistent volumes: none
```

Target design:

```text
k3s namespace: miak-website
Secrets: OpenBao apps/miak-website -> ExternalSecret miak-website
Ingress: miak-it.de and www.miak-it.de -> miak-website service
```

The initial migration imports the exact VPS image into the k3s node and tags it as:

```text
ghcr.io/1a-khan/miak-phoenix-website:cf68f4d37b5750154c115b02cd2b2c91bd838f8c
```

The manifest uses `imagePullPolicy: Never` because this first migration preserves the already-running VPS image instead of releasing a new image from source. Replace this with normal GHCR pull behavior after GitHub Actions builds and pushes website images.

Copy website secrets from VPS env into OpenBao:

```bash
cd /home/dev/Desktop/local-svr/homelab
export KUBECONFIG="$PWD/kubeconfig"
scripts/miak-website-export-secrets-to-openbao.sh
```

Deploy and verify before DNS cutover:

```bash
kubectl apply -f kubernetes/apps/miak-website/namespace.yml
kubectl apply -f kubernetes/apps/miak-website/external-secret.yml
kubectl apply -f kubernetes/apps/miak-website/miak-website.yml
kubectl apply -f kubernetes/apps/miak-website/ingress.yml

kubectl get pods -n miak-website
curl -H "Host: miak-it.de" http://192.168.1.50/healthz
curl -H "Host: www.miak-it.de" http://192.168.1.50/healthz
```

DNS cutover uses OpenTofu. The existing root A/AAAA records for `miak-it.de` must be replaced carefully because an apex CNAME cannot coexist with A/AAAA records.
