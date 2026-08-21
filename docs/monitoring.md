# Monitoring

The monitoring stack uses the `prometheus-community/kube-prometheus-stack` Helm chart.

Pinned chart:

```text
kube-prometheus-stack 88.3.0
```

It installs:

```text
Prometheus
Grafana
Alertmanager
node-exporter
kube-state-metrics
Prometheus Operator
```

## Install Helm Locally

This repo uses a local Helm binary at:

```text
tools/bin/helm
```

Download/install command used:

```bash
mkdir -p tools/bin tools/downloads
curl -fsSL https://get.helm.sh/helm-v3.19.0-linux-amd64.tar.gz -o tools/downloads/helm-v3.19.0-linux-amd64.tar.gz
tar -xzf tools/downloads/helm-v3.19.0-linux-amd64.tar.gz -C tools/downloads
cp tools/downloads/linux-amd64/helm tools/bin/helm
chmod +x tools/bin/helm
```

## Install Stack

```bash
cd /home/dev/Desktop/local-svr/homelab
export KUBECONFIG="$PWD/kubeconfig"

kubectl apply -f kubernetes/platform/monitoring/namespace.yml

kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

tools/bin/helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 88.3.0 \
  --values kubernetes/platform/monitoring/kube-prometheus-stack-values.yml
```

## Check Status

```bash
kubectl get pods -n monitoring
kubectl get pvc -n monitoring
kubectl get ingress -n monitoring
```

## Grafana Login

URL:

```text
https://grafana.miak-it.dev
```

Cloudflare Access protects the URL first.

Grafana username:

```text
admin
```

Get the generated Grafana password:

```bash
kubectl get secret -n monitoring grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

## Notes

For k3s, these components are disabled in the first values file to avoid noisy or unavailable scrape targets:

```text
kubeEtcd
kubeControllerManager
kubeScheduler
kubeProxy
```

SQLite is used for k3s right now, so etcd monitoring is not relevant yet.

