# Cloudflared In Kubernetes

This deploys Cloudflare Tunnel connectors inside k3s.

## Prerequisites

The Cloudflare namespace and tunnel token Secret must exist:

```bash
cd /home/dev/Desktop/local-svr/homelab
export KUBECONFIG="$PWD/kubeconfig"

kubectl get namespace cloudflare
kubectl get secret -n cloudflare cloudflared-token
```

## Deploy

```bash
kubectl apply -f kubernetes/platform/cloudflare/namespace.yml
kubectl apply -f kubernetes/platform/cloudflare/cloudflared.yml
```

## Check Status

```bash
kubectl get pods -n cloudflare
kubectl logs -n cloudflare deployment/cloudflared
```

Expected signals in logs:

```text
Registered tunnel connection
Connection ... registered
```

## Test Public URL

```bash
curl https://hello.miak-it.dev
```

Because `.dev` domains are HTTPS-only in browsers, always use `https://`.

