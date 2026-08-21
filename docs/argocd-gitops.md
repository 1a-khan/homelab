# Argo CD GitOps

Argo CD solves the Coolify auto-deploy problem by watching the GitHub repository and reconciling Kubernetes manifests from `main` into k3s.

Repository:

```text
git@github.com:1a-khan/homelab.git
```

The repository is private, so Argo CD uses a read-only GitHub deploy key. The private key is stored only as an Argo CD repository secret in the cluster, not in Git.

## Design

Argo CD itself is bootstrapped manually with Helm. After that, `homelab-apps` is the root Argo Application and it creates child Applications from:

```text
kubernetes/platform/argocd/applications
```

Secrets are not stored in Git. Applications define `ExternalSecret` resources and External Secrets Operator pulls real secret values from OpenBao.

Automated sync is enabled with:

```text
selfHeal: true
prune: false
```

This means Argo CD will deploy new or changed manifests from `main`, and repair drift, but it will not delete cluster resources just because a manifest was removed from Git. Enable pruning later after the GitOps workflow feels boring and reliable.

## Bootstrap

Run from the homelab repo:

```bash
cd /home/dev/Desktop/local-svr/homelab
export KUBECONFIG="$PWD/kubeconfig"

kubectl apply -f kubernetes/platform/argocd/namespace.yml

./tools/bin/helm repo add argo https://argoproj.github.io/argo-helm
./tools/bin/helm repo update argo

./tools/bin/helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --values kubernetes/platform/argocd/argocd-values.yml \
  --wait
```

Create a read-only GitHub deploy key for Argo CD. Add the public key to the GitHub repository as a read-only deploy key:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/argocd_homelab_deploy_key -C "argocd-homelab-k3s"
gh repo deploy-key add ~/.ssh/argocd_homelab_deploy_key.pub \
  --repo 1a-khan/homelab \
  --title "argocd-homelab-k3s"
```

Store the private key in Argo CD:

```bash
kubectl -n argocd create secret generic repo-homelab-github \
  --from-literal=type=git \
  --from-literal=url='git@github.com:1a-khan/homelab.git' \
  --from-file=sshPrivateKey="$HOME/.ssh/argocd_homelab_deploy_key" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n argocd label secret repo-homelab-github \
  argocd.argoproj.io/secret-type=repository \
  --overwrite
```

Create the GitOps root:

```bash

kubectl apply -f kubernetes/platform/argocd/project.yml
kubectl apply -f kubernetes/platform/argocd/root-application.yml
```

## Access UI

Use port-forward from the laptop:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Open:

```text
https://127.0.0.1:8080
```

Username:

```text
admin
```

Initial password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

After login, change the admin password in the UI and remove the initial secret:

```bash
kubectl -n argocd delete secret argocd-initial-admin-secret
```

## Daily Workflow

1. Change Kubernetes YAML in this repo.
2. Commit and push to `main`.
3. Argo CD detects the Git change and syncs it into k3s.
4. Check status:

```bash
kubectl -n argocd get applications
```

Force a refresh when you do not want to wait:

```bash
kubectl -n argocd annotate application homelab-apps \
  argocd.argoproj.io/refresh=hard --overwrite
```

## What Argo CD Manages

Apps:

```text
calendar-agent
kids-prep
n8n
windmill
```

Platform manifests:

```text
cloudflared
cost dashboard manifests
graph credential generators
postgres
valkey
```

OpenBao, monitoring, logging, reloader, and External Secrets Operator are still Helm/manual bootstrap components for now because their folders contain Helm values or CRD lifecycle pieces. We can move them under Argo CD later with dedicated Helm Applications.
