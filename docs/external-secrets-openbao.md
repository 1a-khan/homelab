# External Secrets With OpenBao

Goal: use OpenBao as the source of truth for application secrets in Kubernetes.

Kubernetes will still create native `Secret` objects when using External Secrets Operator. The difference is that these secrets are reconciled from OpenBao instead of being manually committed or typed into Kubernetes.

## Install External Secrets Operator

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

## Configure OpenBao Kubernetes Auth

The script asks for an OpenBao admin username and password, defaulting to `admin`.

```bash
kubectl apply -f kubernetes/platform/external-secrets/openbao-rbac.yml
scripts/openbao-bootstrap-kubernetes-auth.sh
```

It configures:

```text
auth mount: kubernetes/
policy: kubernetes-app-secrets
role: external-secrets
kv mount: apps/
demo secret: apps/demo/app
```

## Create Store And Demo Secret

```bash
kubectl apply -f kubernetes/platform/external-secrets/cluster-secret-store-openbao.yml
kubectl apply -f kubernetes/platform/external-secrets/demo-namespace.yml
kubectl apply -f kubernetes/platform/external-secrets/demo-external-secret.yml
```

Check:

```bash
kubectl get clustersecretstore openbao
kubectl get externalsecret -n secret-demo
kubectl get secret -n secret-demo openbao-demo
kubectl get secret -n secret-demo openbao-demo -o jsonpath='{.data.username}' | base64 -d; echo
```

If the store was created before OpenBao Kubernetes auth was configured, force one fresh reconciliation:

```bash
kubectl annotate clustersecretstore openbao force-sync="$(date +%s)" --overwrite
kubectl annotate externalsecret -n secret-demo openbao-demo force-sync="$(date +%s)" --overwrite
```

Expected username:

```text
demo-user
```

Verified on 2026-08-17:

```text
ClusterSecretStore openbao: Valid / Ready=True
ExternalSecret openbao-demo: SecretSynced / Ready=True
Synced username: demo-user
```
