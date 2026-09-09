# Commands

Run these from the `homelab` directory unless a command says otherwise.

## 1. Initialize Git

```bash
git init
git status
```

You are creating the source of truth for the platform.

## 2. Prepare SSH Key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/homelab -C "homelab-k3s"
cat ~/.ssh/homelab.pub
```

If you already have an SSH key you want to use, only run the `cat` command.

## 3. Create Local Ansible Files

```bash
cp ansible/inventory.example.ini ansible/inventory.ini
cp ansible/group_vars/all.example.yml ansible/group_vars/all.yml
```

Edit both files with your mini PC IP, SSH user, public key, and a long random k3s token.

Generate the k3s token with:

```bash
openssl rand -hex 32
```

## 4. Install Ansible Collections

```bash
ansible-galaxy collection install ansible.posix community.general
```

These collections provide firewall, sysctl, timezone, and SSH key modules.

## 5. Test Password SSH Before Hardening

```bash
ssh YOUR_USER@MINI_PC_IP
```

Confirm your user can run:

```bash
sudo whoami
```

It should print `root`.

## 6. Run Bootstrap

```bash
cd ansible
ansible-playbook playbooks/00-bootstrap.yml --ask-pass --ask-become-pass
```

This installs your SSH key, hardens SSH, installs baseline packages, and enables UFW.

## 7. Test Key-Based SSH

```bash
ssh -i ~/.ssh/homelab YOUR_USER@MINI_PC_IP
```

This must work before continuing.

## 8. Test Ansible Ping

```bash
ansible k3s_servers -m ping
```

This proves your laptop can automate the server without passwords.

## 9. Install k3s

```bash
ansible-playbook playbooks/10-k3s.yml
```

This installs k3s and fetches kubeconfig into `homelab/kubeconfig`.

If an older run placed it under `homelab/ansible/kubeconfig`, move it once:

```bash
mv /home/dev/Desktop/local-svr/homelab/ansible/kubeconfig /home/dev/Desktop/local-svr/homelab/kubeconfig
```

## 10. Use kubeconfig From Laptop

From the `homelab` directory:

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide
kubectl get pods -A
```

This works because the Ansible playbook rewrites the server address in `kubeconfig` from `127.0.0.1` to the mini PC LAN IP.

## 11. Deploy Test App

```bash
kubectl apply -f kubernetes/test-app/namespace.yml
kubectl apply -f kubernetes/test-app/whoami.yml
kubectl get pods -n test-app
kubectl get svc -n test-app
```

Cloudflare Tunnel comes after this app is healthy.

## 12. Apply Test App Ingress

```bash
kubectl apply -f kubernetes/test-app/ingress.yml
kubectl get ingress -n test-app
curl -H "Host: hello.miak-it.dev" http://192.168.8.140
```

The `curl` command tests Traefik locally before DNS or Cloudflare Tunnel are involved.

## 13. Deploy OpenBao Target

From the `homelab` directory:

```bash
export KUBECONFIG="$PWD/kubeconfig"

kubectl apply -f kubernetes/apps/openbao/namespace.yml

./tools/bin/helm repo add openbao https://openbao.github.io/openbao-helm
./tools/bin/helm repo update openbao

./tools/bin/helm upgrade --install openbao openbao/openbao \
  --namespace openbao \
  --version 0.29.1 \
  --values kubernetes/apps/openbao/openbao-values.yml
```

## 14. Check OpenBao Target

```bash
kubectl get pods,pvc,svc,ingress -n openbao
kubectl logs -n openbao openbao-0 --tail=100
kubectl exec -n openbao openbao-0 -- bao status || true
```

A fresh target should show `Initialized false` and `Sealed true` until we restore or initialize it.

Check Cloudflare Access:

```bash
curl -I https://openbao.miak-it.dev
```

Expected result: HTTP `302` redirect to your Cloudflare Access login page.

## 15. OpenBao VPS Inventory

Run these after confirming the correct VPS SSH user, key, and port:

```bash
ssh -o IdentitiesOnly=yes -i ~/.ssh/<vps-key> -p <ssh-port> <vps-user>@<vps-host>
```

Then inspect without changing anything:

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}'
docker compose ls
docker volume ls
docker network ls
docker ps --format '{{.Names}}' | grep -Ei 'openbao|vault|bao'
```

After finding the OpenBao container name:

```bash
docker inspect <openbao-container> --format '{{json .Mounts}}'
docker inspect <openbao-container> --format '{{range .Config.Env}}{{println .}}{{end}}'
docker logs --tail 100 <openbao-container>
```

## 16. OpenBao Snapshot And Restore

Create a Raft snapshot from the current VPS OpenBao. The script asks for an OpenBao admin username and password, defaulting to `admin`.

```bash
cd /home/dev/Desktop/local-svr/homelab
scripts/openbao-snapshot-from-vps.sh
```

Restore the latest snapshot into the k3s OpenBao target:

```bash
scripts/openbao-restore-to-k3s.sh backups/openbao/openbao-raft-20260817T130205Z.snap
```

After restore, unseal with 3 original VPS OpenBao unseal keys:

```bash
scripts/openbao-unseal-k3s.sh
```

## 17. OpenBao User Tests

Check restored userpass users. The script asks for an OpenBao admin username and password, defaulting to `admin`.

```bash
cd /home/dev/Desktop/local-svr/homelab
scripts/openbao-list-users-k3s.sh
```

Test user login. The script asks for the password silently, checks the issued token, then revokes the test token.

```bash
scripts/openbao-test-user-login-k3s.sh admin
scripts/openbao-test-user-login-k3s.sh terraform
scripts/openbao-test-user-login-k3s.sh laptop
```

## OpenBao Daily Admin

Production UI:

```text
https://openbao.miak-it.com/ui/
```

Check status from inside k3s:

```bash
kubectl exec -n openbao openbao-0 -- bao status
```

Use the CLI through the public production hostname:

```bash
export BAO_ADDR="https://openbao.miak-it.com"
bao login
bao status
```

Use the CLI through Kubernetes exec. This avoids Cloudflare/browser/session issues. Prefer logging in as `admin`; use a root token only for break-glass recovery.

```bash
kubectl exec -n openbao -it openbao-0 -- sh
bao login -method=userpass username=admin
bao status
```

Create or update a userpass user:

```bash
bao write auth/userpass/users/USERNAME password='NEW_PASSWORD' policies='POLICY_NAME'
```

Create a simple read-only policy for one app path:

```bash
bao policy write app-readonly - <<'POLICY'
path "apps/data/my-app/*" {
  capabilities = ["read"]
}

path "apps/metadata/my-app/*" {
  capabilities = ["read", "list"]
}
POLICY
```

Store a normal key/value secret:

```bash
bao kv put apps/my-app/config username="my-user" password="my-password"
bao kv get apps/my-app/config
```

Store an SSH private/public keypair as a secret:

```bash
bao kv put apps/my-app/ssh \
  private_key=@/home/dev/.ssh/my_key \
  public_key=@/home/dev/.ssh/my_key.pub
```

## 18. External Secrets With OpenBao

Install External Secrets Operator:

```bash
cd /home/dev/Desktop/local-svr/homelab
export KUBECONFIG="$PWD/kubeconfig"

kubectl apply -f kubernetes/platform/external-secrets/namespace.yml

./tools/bin/helm repo add external-secrets https://charts.external-secrets.io
./tools/bin/helm repo update external-secrets

./tools/bin/helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --version 2.9.0 \
  --values kubernetes/platform/external-secrets/external-secrets-values.yml
```

Configure OpenBao Kubernetes auth and test secret sync:

```bash
kubectl apply -f kubernetes/platform/external-secrets/openbao-rbac.yml
scripts/openbao-bootstrap-kubernetes-auth.sh
kubectl apply -f kubernetes/platform/external-secrets/cluster-secret-store-openbao.yml
kubectl apply -f kubernetes/platform/external-secrets/demo-namespace.yml
kubectl apply -f kubernetes/platform/external-secrets/demo-external-secret.yml
kubectl get externalsecret -n secret-demo
kubectl get secret -n secret-demo openbao-demo
kubectl get secret -n secret-demo openbao-demo -o jsonpath='{.data.username}' | base64 -d; echo
```

Force reconciliation if the store existed before OpenBao auth was configured:

```bash
kubectl annotate clustersecretstore openbao force-sync="$(date +%s)" --overwrite
kubectl annotate externalsecret -n secret-demo openbao-demo force-sync="$(date +%s)" --overwrite
```

## 19. Stage n8n Migration

The staging hostname is:

```text
https://n8n.miak-it.dev
```

Cloudflare should already have a proxied tunnel record and Access app for this hostname.

Start by copying the current VPS n8n secrets into OpenBao. The script asks for an OpenBao admin username and password, defaulting to `admin`.

```bash
cd /home/dev/Desktop/local-svr/homelab
export KUBECONFIG="$PWD/kubeconfig"

kubectl apply -f kubernetes/apps/n8n/namespace.yml
scripts/n8n-export-secrets-to-openbao.sh
kubectl apply -f kubernetes/apps/n8n/external-secret.yml
kubectl get externalsecret -n n8n n8n
kubectl get secret -n n8n n8n
```

Deploy the shared platform services once:

```bash
scripts/platform-bootstrap-secrets-openbao.sh
kubectl apply -f kubernetes/platform/postgres/namespace.yml
kubectl apply -f kubernetes/platform/postgres/external-secret.yml
kubectl apply -f kubernetes/platform/postgres/postgres.yml
kubectl apply -f kubernetes/platform/valkey/namespace.yml
kubectl apply -f kubernetes/platform/valkey/external-secret.yml
kubectl apply -f kubernetes/platform/valkey/valkey.yml
kubectl get pods -n database
kubectl get pods -n valkey
```

Deploy the staging n8n services:

```bash
kubectl apply -f kubernetes/apps/n8n/n8n.yml
kubectl apply -f kubernetes/apps/n8n/ingress.yml
```

Take a backup from the current VPS and restore it into k3s:

```bash
scripts/n8n-backup-from-vps.sh
scripts/n8n-restore-to-k3s.sh
kubectl get pods -n n8n
```

If n8n logs show `Mismatching encryption keys` or `Credentials could not be decrypted`, sync the key from the backed-up n8n config into OpenBao and restart:

```bash
scripts/n8n-sync-encryption-key-from-backup.sh
kubectl get externalsecret -n n8n n8n
kubectl rollout restart deployment -n n8n n8n n8n-worker n8n-task-runners
kubectl rollout status deployment -n n8n n8n
kubectl rollout status deployment -n n8n n8n-worker
kubectl rollout status deployment -n n8n n8n-task-runners
```

After staging works, schedule a short production cutover:

```text
1. Pause/stop n8n writes on the VPS.
2. Take a final n8n backup from the VPS.
3. Restore the final backup to k3s.
4. Switch n8n.miak-it.com DNS/tunnel routing to k3s.
5. Verify UI login, workflows, webhooks, OAuth redirects, and API clients.
```

## 20. OpenTofu With OpenBao IaC User

Store the Cloudflare API token in OpenBao and create a dedicated `iac` user:

```bash
cd /home/dev/Desktop/local-svr/homelab
scripts/iac-bootstrap-cloudflare-openbao.sh
```

Run Cloudflare OpenTofu through the wrapper. It asks for the `iac` password, fetches the Cloudflare token from OpenBao, exports it only for the child `tofu` process, and revokes the temporary OpenBao token afterward.

```bash
scripts/iac-tofu-cloudflare.sh plan
scripts/iac-tofu-cloudflare.sh apply
```

Import an existing Cloudflare DNS record before OpenTofu manages it:

```bash
scripts/iac-import-cloudflare-dns-record.sh \
  cloudflare_dns_record.n8n_prod \
  0c7c24e4a1b41fc6cd480c93bfdfdd99 \
  n8n.miak-it.com
```

Then preview the production cutover:

```bash
scripts/iac-tofu-cloudflare.sh plan
```

For n8n production cutover, the expected DNS change is:

```text
n8n.miak-it.com
from A 116.203.131.147
to   CNAME <tunnel-id>.cfargotunnel.com
```

## 21. OpenBao Azure Secrets Engine

OpenBao is configured to auto-download and register the Azure secrets plugin from the Helm values. The OpenBao StatefulSet uses the `OnDelete` update strategy, so `kubectl rollout restart` is not enough. After changing plugin config, delete the pod, let Kubernetes recreate it, then unseal it.

```bash
cd /home/dev/Desktop/local-svr/homelab
export KUBECONFIG="$PWD/kubeconfig"

kubectl delete pod -n openbao openbao-0
kubectl wait --for=condition=Ready pod/openbao-0 -n openbao --timeout=180s || true
kubectl exec -n openbao openbao-0 -- bao status || true

scripts/openbao-unseal-k3s.sh
```

Configure the Azure secrets engine. The script asks for your OpenBao `admin` login and your Azure bootstrap app details. Do not paste those secrets into chat.

```bash
scripts/openbao-configure-azure-secrets-engine.sh
```

Inputs you need from Azure:

```text
Azure subscription ID
Azure tenant ID
Azure bootstrap app client ID
Azure bootstrap app client secret
Optional existing Terraform app registration Object ID
```

For Azure, prefer using an existing Terraform app registration Object ID. OpenBao then creates temporary passwords for that existing app instead of creating a brand-new app/service principal for every lease. This avoids common Microsoft Entra ID propagation delays.

Create the Terraform app once in Azure:

```text
Microsoft Entra ID -> App registrations -> New registration
Name: MIAK-Terraform
Supported account types: Single tenant
```

Then assign that app `Contributor` on the target subscription:

```text
Subscriptions -> target subscription -> Access control (IAM) -> Add role assignment
Role: Contributor
Member type: User, group, or service principal
Member: MIAK-Terraform
```

Use the app registration `Object ID` when the script asks:

```text
Existing Terraform app registration Object ID
```

Defaults are okay after that:

```text
Generated Terraform role: Contributor
Generated credential scope: /subscriptions/<subscription-id>
TTL: 1h
Max TTL: 4h
```

Run OpenTofu/Terraform with dynamic Azure credentials from OpenBao:

```bash
scripts/terraform-with-openbao-azure.sh tofu -chdir=terraform/azure plan
scripts/terraform-with-openbao-azure.sh tofu -chdir=terraform/azure apply
```

Quick safe test without printing the Azure client secret:

```bash
scripts/terraform-with-openbao-azure.sh sh -lc 'echo "$ARM_SUBSCRIPTION_ID"; echo "$ARM_TENANT_ID"; test -n "$ARM_CLIENT_ID"; test -n "$ARM_CLIENT_SECRET"; echo "azure env ok"'
```

## 22. Microsoft Graph App Credentials

Configure OpenBao roles for existing Entra app registrations created by `/home/dev/Desktop/miak-management-azure`:

```bash
cd /home/dev/Desktop/miak-management-azure
scripts/export-public-outputs.sh
scripts/openbao-configure-graph-app-roles.sh
```

Apply the Kubernetes dynamic credential sync resources:

```bash
cd /home/dev/Desktop/local-svr/homelab
export KUBECONFIG="$PWD/kubeconfig"

kubectl apply -f kubernetes/platform/graph-credentials/graph-credential-generators.yml
kubectl apply -f kubernetes/platform/graph-credentials/cluster-external-secrets.yml
```

Opt a namespace into MailMover credentials:

```bash
kubectl label namespace MY_NAMESPACE miak-it.com/graph-mail-mover=true --overwrite
```

Opt a namespace into OneDrive credentials:

```bash
kubectl label namespace MY_NAMESPACE miak-it.com/graph-onedrive-manager=true --overwrite
```

Reloader is installed. Annotate workloads so they restart when the synced credential changes:

```yaml
metadata:
  annotations:
    secret.reloader.stakater.com/reload: "graph-mail-mover"
```

## 23. Safe Server Maintenance

Run a report-only maintenance preflight first. This does not install upgrades or reboot:

```bash
cd /home/dev/Desktop/local-svr/homelab/ansible
ansible-playbook playbooks/70-maintenance-upgrade.yml
```

The playbook saves a timestamped report under:

```text
maintenance-reports/
```

Run package upgrades only after reviewing the preflight output:

```bash
cd /home/dev/Desktop/local-svr/homelab/ansible
ansible-playbook playbooks/70-maintenance-upgrade.yml -e maintenance_upgrade_apply=true
```

Allow a reboot only during a maintenance window:

```bash
cd /home/dev/Desktop/local-svr/homelab/ansible
ansible-playbook playbooks/70-maintenance-upgrade.yml \
  -e maintenance_upgrade_apply=true \
  -e maintenance_reboot_if_required=true
```

Use `maintenance_apt_upgrade=full` only when you intentionally want package removals/installations handled by apt:

```bash
ansible-playbook playbooks/70-maintenance-upgrade.yml \
  -e maintenance_upgrade_apply=true \
  -e maintenance_apt_upgrade=full
```
