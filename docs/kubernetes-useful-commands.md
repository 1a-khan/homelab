# Kubernetes Useful Commands

Run these from the `homelab` directory unless noted otherwise.

## Use This Cluster

```bash
export KUBECONFIG="$PWD/kubeconfig"
```

`kubeconfig` tells `kubectl` which Kubernetes cluster to talk to and which credentials to use.

Check the active context:

```bash
kubectl config current-context
```

## Cluster Health

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl get services -A
```

Short aliases:

```bash
kubectl get ns
kubectl get svc -A
```

## Namespaces

A namespace is like a folder or project area inside Kubernetes.

Common examples:

```text
kube-system   Kubernetes internal components
default       Default namespace when none is specified
test-app      Our test application namespace
```

List namespaces:

```bash
kubectl get namespaces
kubectl get ns
```

Show pods in one namespace:

```bash
kubectl get pods -n test-app
```

Show pods in all namespaces:

```bash
kubectl get pods -A
```

## Test App

Deploy the test app:

```bash
kubectl apply -f kubernetes/test-app/namespace.yml
kubectl apply -f kubernetes/test-app/whoami.yml
```

Check it:

```bash
kubectl get pods -n test-app
kubectl get svc -n test-app
```

Read logs from the deployment:

```bash
kubectl logs -n test-app deployment/whoami
```

Read logs from a specific pod:

```bash
kubectl logs -n test-app POD_NAME
```

## Temporary Port Forward

```bash
kubectl -n test-app port-forward svc/whoami 8080:80
```

Meaning:

```text
kubectl         Kubernetes command-line tool
-n test-app    Use the test-app namespace
port-forward   Create a temporary tunnel from laptop to Kubernetes
svc/whoami     Target the Service named whoami
8080:80        Laptop port 8080 forwards to service port 80
```

While it is running, this reaches the app:

```bash
curl http://localhost:8080
```

Stop it with:

```text
Ctrl + C
```

This does not create or change any Kubernetes resource.

## Find And Stop A Local Process

Show running processes:

```bash
ps aux
```

Find a `kubectl port-forward` process:

```bash
ps aux | grep port-forward
```

Stop a process by PID:

```bash
kill PID_NUMBER
```

Example:

```bash
kill 12345
```

## Cloudflare Tunnel Secret

After OpenTofu creates the Cloudflare Tunnel, show the tunnel token:

```bash
cd /home/dev/Desktop/local-svr/homelab/terraform/cloudflare
tofu output -raw tunnel_token
```

The output is sensitive. Do not paste it into chat or commit it to Git.

Create a namespace for Cloudflare components:

```bash
cd /home/dev/Desktop/local-svr/homelab
export KUBECONFIG="$PWD/kubeconfig"
kubectl create namespace cloudflare
```

Create a Kubernetes Secret from the OpenTofu tunnel token:

```bash
kubectl -n cloudflare create secret generic cloudflared-token \
  --from-literal=tunnel-token="$(cd terraform/cloudflare && tofu output -raw tunnel_token)"
```

Meaning:

```text
kubectl                    Kubernetes command-line tool
-n cloudflare              Use the cloudflare namespace
create secret generic      Create a simple key/value Kubernetes Secret
cloudflared-token          Name of the Secret
--from-literal=...         Create the Secret value from text
tunnel-token               Key inside the Secret
$(...)                     Run this shell command and insert its output
tofu output -raw ...       Read the sensitive tunnel token from OpenTofu
```

Verify the Secret exists without printing its value:

```bash
kubectl get secret -n cloudflare cloudflared-token
```

Avoid this unless you intentionally need to inspect encoded secret data:

```bash
kubectl get secret -n cloudflare cloudflared-token -o yaml
```

## Cloudflared Deployment

Deploy Cloudflare Tunnel connectors in Kubernetes:

```bash
kubectl apply -f kubernetes/platform/cloudflare/namespace.yml
kubectl apply -f kubernetes/platform/cloudflare/cloudflared.yml
```

Check pods:

```bash
kubectl get pods -n cloudflare
```

Check logs:

```bash
kubectl logs -n cloudflare deployment/cloudflared
```

Test the public route:

```bash
curl https://hello.miak-it.dev
```
