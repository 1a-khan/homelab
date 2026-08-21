# OpenBao Migration

Goal: migrate the existing `openbao.miak-it.com` service from the Hetzner VPS to the on-prem k3s cluster with complete data.

The safe order is:

1. Inventory the current VPS OpenBao container and storage backend.
2. Take a backup from the current OpenBao instance.
3. Deploy OpenBao on k3s at `openbao.miak-it.dev`.
4. Restore the backup into k3s.
5. Verify secrets, auth methods, policies, mounts, audit, and UI login.
6. Switch `openbao.miak-it.com` only after the restored instance is proven.

Status: production cutover completed on 2026-08-21.

Production hostname:

```text
https://openbao.miak-it.com
```

Current target:

```text
Cloudflare proxied CNAME -> 50327130-69c0-4ff9-a8c2-d44d516dd17d.cfargotunnel.com -> k3s Traefik -> openbao namespace
```

## Target Deployment

The on-prem target uses the official OpenBao Helm chart:

```text
chart: openbao/openbao
chart version: 0.29.1
app version: 2.6.1
namespace: openbao
host: openbao.miak-it.dev
storage: integrated Raft on local-path PVC
aws plugin: ghcr.io/openbao/openbao-plugin-secrets-aws v0.3.1
```

The chart is configured with Raft even though the current cluster has one physical node. This is better than file storage because it gives us official snapshot backup and restore workflows, and later we can scale to more OpenBao pods/nodes.

The current VPS config uses the OpenBao AWS secrets plugin. The k3s config keeps the same plugin image, version, binary name, and checksum.

## Current VPS Discovery

Collected on 2026-08-17:

```text
host: dev-prod-16gb-nbg1
container: openbao-boyl1uvbqpc717bjozsutamd-133124215218
image: openbao/openbao:2.6.1
public hostname: openbao.miak-it.com
storage: raft
seal type: shamir
shares: 5
threshold: 3
state: initialized, unsealed, active
data volume: boyl1uvbqpc717bjozsutamd_openbao-data
plugin volume: boyl1uvbqpc717bjozsutamd_openbao-plugins
data path: /var/lib/docker/volumes/boyl1uvbqpc717bjozsutamd_openbao-data/_data
```

## Deploy Empty Target

Do not switch production DNS before restore and verification.

```bash
cd /home/dev/Desktop/local-svr/homelab
export KUBECONFIG="$PWD/kubeconfig"

kubectl apply -f kubernetes/apps/openbao/namespace.yml

./tools/bin/helm repo add openbao https://openbao.github.io/openbao-helm
./tools/bin/helm repo update openbao

./tools/bin/helm upgrade --install openbao openbao/openbao \
  --namespace openbao \
  --version 0.29.1 \
  --values kubernetes/apps/openbao/openbao-values.yml
```

Check:

```bash
kubectl get pods -n openbao
kubectl get pvc -n openbao
kubectl get ingress -n openbao
```

## Current VPS Inventory Commands

Run these only after SSH access to the VPS is confirmed.

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}'
docker compose ls
docker volume ls
docker network ls
```

Find OpenBao configuration:

```bash
docker inspect openbao --format '{{json .Mounts}}'
docker inspect openbao --format '{{range .Config.Env}}{{println .}}{{end}}'
docker logs --tail 100 openbao
```

If the container name is different:

```bash
docker ps --format '{{.Names}}' | grep -Ei 'openbao|vault|bao'
```

## Backup Path A: Current OpenBao Uses Raft

This is the preferred path.

Use the helper script from your laptop. It asks for the OpenBao token silently and stores the snapshot under ignored local `backups/`.

```bash
cd /home/dev/Desktop/local-svr/homelab
scripts/openbao-snapshot-from-vps.sh
```

Set the address and token on the VPS:

```bash
export BAO_ADDR="http://127.0.0.1:8200"
export BAO_TOKEN="REDACTED"
```

Confirm health and storage:

```bash
bao status
bao operator raft list-peers
```

Create a full Raft snapshot:

```bash
mkdir -p ~/openbao-migration
bao operator raft snapshot save ~/openbao-migration/openbao-raft.snap
sha256sum ~/openbao-migration/openbao-raft.snap > ~/openbao-migration/openbao-raft.snap.sha256
```

Copy it to the laptop:

```bash
scp -i ~/.ssh/<vps-key> <vps-user>@<vps-host>:~/openbao-migration/openbao-raft.snap ./openbao-raft.snap
scp -i ~/.ssh/<vps-key> <vps-user>@<vps-host>:~/openbao-migration/openbao-raft.snap.sha256 ./openbao-raft.snap.sha256
sha256sum -c openbao-raft.snap.sha256
```

## Backup Path B: Current OpenBao Uses File Storage

If the current OpenBao container uses `storage "file"`, take an offline backup.

1. Stop writes to OpenBao.
2. Stop the OpenBao container.
3. Archive the mounted data directory.
4. Start the old OpenBao container again.

Example:

```bash
docker stop openbao
sudo tar --xattrs --acls -czf ~/openbao-migration/openbao-file-storage.tgz /path/to/openbao/data
sudo sha256sum ~/openbao-migration/openbao-file-storage.tgz > ~/openbao-migration/openbao-file-storage.tgz.sha256
docker start openbao
```

This path needs extra care because file-storage backups should be taken offline.

## Restore To k3s

After the target OpenBao pod exists, copy the snapshot into the pod:

```bash
kubectl -n openbao cp ./openbao-raft.snap openbao-0:/tmp/openbao-raft.snap
```

Initialize/unseal strategy depends on the snapshot and target state. We will do this interactively after seeing the current VPS backend, seal type, and unseal method.

The helper script performs the temporary target initialization and restore:

```bash
cd /home/dev/Desktop/local-svr/homelab
scripts/openbao-restore-to-k3s.sh backups/openbao/openbao-raft-20260817T130205Z.snap
```

After restore, unseal with 3 of the original VPS OpenBao unseal keys:

```bash
scripts/openbao-unseal-k3s.sh
```

## Verify Before DNS Switch

```bash
bao status
bao secrets list
bao auth list
bao policy list
```

Also verify the UI:

```text
https://openbao.miak-it.dev
```

## Production DNS Switch

Only after verification:

1. Add `openbao.miak-it.com` to the Cloudflare Tunnel config.
2. Add or update the Kubernetes Ingress host.
3. Change Cloudflare DNS for `openbao.miak-it.com` from the Hetzner A record to the tunnel CNAME.
4. Keep the old VPS OpenBao stopped but not deleted until backups are verified.
