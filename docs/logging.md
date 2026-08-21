# Logging

The logging stack uses:

```text
Loki 7.3.0 chart / Loki 3.6.12
Alloy 1.11.1 chart / Alloy 1.18.1
```

## Components

```text
Loki   stores and queries logs
Alloy  collects Kubernetes pod logs and sends them to Loki
Grafana queries Loki through a datasource ConfigMap
```

## Install

```bash
cd /home/dev/Desktop/local-svr/homelab
export KUBECONFIG="$PWD/kubeconfig"

kubectl apply -f kubernetes/platform/logging/namespace.yml

tools/bin/helm upgrade --install loki grafana/loki \
  --namespace logging \
  --version 7.3.0 \
  --values kubernetes/platform/logging/loki-values.yml

tools/bin/helm upgrade --install alloy grafana/alloy \
  --namespace logging \
  --version 1.11.1 \
  --values kubernetes/platform/logging/alloy-values.yml

kubectl apply -f kubernetes/platform/logging/grafana-loki-datasource.yml
kubectl rollout restart deployment/monitoring-grafana -n monitoring
```

## Check Status

```bash
kubectl get pods -n logging
kubectl get pvc -n logging
kubectl get svc -n logging
```

## Check Logs In Grafana

Open:

```text
https://grafana.miak-it.dev
```

Go to:

```text
Explore -> Loki
```

Try queries:

```logql
{namespace="kube-system"}
```

```logql
{namespace="monitoring"}
```

```logql
{namespace="test-app"}
```

## Notes

This first setup uses `loki.source.kubernetes`, which tails pod logs through the Kubernetes API. It is simple and good for the first working logging stack.

Later improvements:

```text
collect host auth logs
collect syslog/journal logs
add alerts for failed SSH logins
add retention and backup policy for Loki data
consider object storage for longer log retention
```

