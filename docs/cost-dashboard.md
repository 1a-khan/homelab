# Cost Dashboard

The cost dashboard exposes static cost assumptions as Prometheus metrics and renders them in Grafana.

## Current Inputs

```text
Mini PC hardware purchase: 150 EUR
Purchase date: 2026-08-14
Hardware amortization: 36 months
Estimated power usage: 25 W
Electricity price: 0.35 EUR/kWh
Hetzner VPS: 17 EUR/month
Backup cost: 0 EUR/month
miak-it.dev domain cost: 0 EUR/year placeholder
```

Update these values in:

```text
kubernetes/platform/costs/cost-exporter.yml
```

## Install

```bash
cd /home/dev/Desktop/local-svr/homelab
export KUBECONFIG="$PWD/kubeconfig"

kubectl apply -f kubernetes/platform/costs/namespace.yml
kubectl apply -f kubernetes/platform/costs/cost-exporter.yml
kubectl apply -f kubernetes/platform/costs/grafana-dashboard-costs.yml
```

## Check

```bash
kubectl get pods -n costs
kubectl get servicemonitor -n costs
```

Prometheus query examples:

```promql
homelab_hardware_purchase_cost_eur
homelab_vps_cost_eur_per_month
homelab_power_watts / 1000 * 24 * 30.4375 * homelab_electricity_price_eur_per_kwh
```

## Grafana

Open:

```text
https://grafana.miak-it.dev
```

Look for:

```text
Homelab Costs
```

