# Microsoft Graph Credentials With OpenBao

Goal: Python apps use Microsoft Graph without hardcoded client secrets.

Terraform/OpenTofu creates the Entra app registrations and Graph permission grants. OpenBao creates temporary client secrets for those existing app registrations. External Secrets Operator syncs the current credential into Kubernetes Secrets. Reloader restarts workloads when the Secret changes.

## One-Time Platform Setup

Reloader is installed in namespace `reloader`.

Graph dynamic credential sync resources live here:

```text
kubernetes/platform/graph-credentials/graph-credential-generators.yml
kubernetes/platform/graph-credentials/cluster-external-secrets.yml
```

They define:

```text
azure/creds/mail-mover        -> Kubernetes Secret graph-mail-mover
azure/creds/onedrive-manager  -> Kubernetes Secret graph-onedrive-manager
azure/creds/calendar-agent    -> Kubernetes Secret graph-calendar-agent
```

## Configure OpenBao Roles

From the Azure-management repo:

```bash
cd /home/dev/Desktop/miak-management-azure
scripts/export-public-outputs.sh
scripts/openbao-configure-graph-app-roles.sh
```

The script creates OpenBao roles for the existing Entra apps and updates the Kubernetes auth policy so External Secrets Operator can read `azure/creds/*`.

Run it again after labeling new Graph app namespaces. It binds OpenBao Kubernetes auth to `external-secrets` plus namespaces that have Graph credential labels.

## Opt In A Namespace

For an app that needs MailMover:

```bash
kubectl label namespace MY_NAMESPACE miak-it.com/graph-mail-mover=true --overwrite
kubectl create serviceaccount external-secrets -n MY_NAMESPACE
```

For an app that needs OneDriveManager:

```bash
kubectl label namespace MY_NAMESPACE miak-it.com/graph-onedrive-manager=true --overwrite
kubectl create serviceaccount external-secrets -n MY_NAMESPACE
```

For an app that needs CalendarAgent:

```bash
kubectl label namespace MY_NAMESPACE miak-it.com/graph-calendar-agent=true --overwrite
kubectl create serviceaccount external-secrets -n MY_NAMESPACE
```

External Secrets Operator then creates one or both Secrets in that namespace:

```text
graph-mail-mover
graph-onedrive-manager
graph-calendar-agent
```

## Use In A Deployment

Add the matching Reloader annotation and consume the Secret as env vars:

```yaml
metadata:
  annotations:
    secret.reloader.stakater.com/reload: "graph-mail-mover"
spec:
  template:
    spec:
      containers:
        - name: app
          envFrom:
            - secretRef:
                name: graph-mail-mover
```

The app receives:

```text
AZURE_TENANT_ID
AZURE_CLIENT_ID
AZURE_CLIENT_SECRET
AZURE_AUTHORITY_HOST
```

## Rotation Behavior

The ClusterExternalSecret refresh interval is `12h`.

The OpenBao role TTL is configured by `/home/dev/Desktop/miak-management-azure/scripts/openbao-configure-graph-app-roles.sh`; default is `720h` (30 days), max TTL `2160h` (90 days).

On each refresh, OpenBao creates a new credential for the existing Entra app registration, Kubernetes Secret data changes, and Reloader restarts annotated workloads.

## Calendar Agent Pipeline Test

From the Azure management repo, create the app registration and export non-secret IDs:

```bash
cd /home/dev/Desktop/miak-management-azure
tofu plan
tofu apply
scripts/export-public-outputs.sh
```

Grant the new app mailbox-scoped calendar access to `support@miak-it.de`:

```bash
pwsh ./calendar-rbacsetup.ps1 -TargetMailboxes support@miak-it.de
```

Configure OpenBao to create rotating secrets for the app:

```bash
scripts/openbao-configure-graph-app-roles.sh
```

Create the Calendar Agent API key in OpenBao:

```bash
cd /home/dev/Desktop/local-svr/homelab
scripts/calendar-agent-bootstrap-api-key-openbao.sh
```

Apply the Kubernetes pieces:

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl apply -f kubernetes/platform/graph-credentials/graph-credential-generators.yml
kubectl apply -f kubernetes/platform/graph-credentials/cluster-external-secrets.yml
kubectl apply -f kubernetes/apps/calendar-agent/namespace.yml
kubectl apply -f kubernetes/apps/calendar-agent/external-secret-api-key.yml
kubectl apply -f kubernetes/apps/calendar-agent/calendar-agent-api.yml
```

Check sync and rollout:

```bash
kubectl get externalsecret -n calendar-agent
kubectl get secret -n calendar-agent graph-calendar-agent calendar-agent-api-key
kubectl rollout status deployment/calendar-agent-api-internal -n calendar-agent
kubectl rollout status deployment/calendar-agent-api-external -n calendar-agent
```

Inside Kubernetes, use the no-auth service:

```text
http://calendar-agent-api.calendar-agent.svc.cluster.local
```

For laptop or public access later, expose the API-key protected service:

```text
calendar-agent-api-external.calendar-agent.svc.cluster.local
```
