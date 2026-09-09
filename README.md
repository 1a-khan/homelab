# My Homelab — Cloud Infrastructure, GitOps & Security

This is my personal homelab. I built it to put my Cloud Architect training into practice and to understand how infrastructure, deployments, security, and day-to-day operations fit together.

I run a single-node k3s Kubernetes platform on a mini PC behind an LTE router, with Cloudflare Tunnel providing access to selected services. I use open-source software and my own scripts to build an environment I can understand, maintain, and improve.

## What I work on here

- **Infrastructure as code:** Terraform-compatible configuration, operated with OpenTofu, for Cloudflare, Hetzner, and local KVM virtual machines.
- **Configuration management:** Ansible for server bootstrap, package installation, and k3s setup.
- **GitOps:** Helm and Argo CD for Kubernetes applications and deployment configuration stored in Git.
- **Secrets management:** OpenBao and External Secrets Operator to supply application credentials without committing their values.
- **Observability:** Prometheus and Grafana for metrics and dashboards, with Loki and Alloy for logs.
- **Recovery:** Backup and restore scripts for applications and OpenBao, with supporting migration runbooks.

I also use Wazuh for host security monitoring and vulnerability reporting, Trivy for repository and Kubernetes workload scanning, and Renovate configuration for dependency updates. The playbooks and helper scripts for these are included here. My wider workflow includes CI/CD security scanning; this repository does not contain every pipeline or every component of the running environment.

## How I manage the work

Even though this is a personal lab, I apply the project and IT service management practices I learned during my Cloud Architect continuing education (*Weiterbildung*).

I use Notion to track bugs, changes, architectural decisions, releases, and configuration items in a CMDB. I keep infrastructure and deployment configuration in Git so I can review changes and understand how the environment has evolved. My private operational records and raw security reports are not part of this public showcase.

## A practical example: vulnerability remediation

After adding Wazuh, I used its vulnerability report to identify server packages that needed attention and patched the server without losing data. This helped me connect security findings with practical maintenance and recovery planning.

I have working backups and a restore approach. I treat recovery as an operational responsibility, and I do not equate a successful backup with proof that every recovery scenario has been tested.

## Repository guide

| Directory | What I keep here |
| --- | --- |
| [ansible/](ansible/) | Server configuration and installation playbooks |
| [terraform/](terraform/) | Infrastructure definitions and example inputs |
| [kubernetes/](kubernetes/) | Application manifests, Helm values, and Argo CD configuration |
| [scripts/](scripts/) | Operational helpers, secret integration, backups, and restores |
| [apps/](apps/) | Application code used in the lab |
| [docs/](docs/) | Setup notes, decisions, and operational runbooks |

Useful starting points:

- [GitOps with Argo CD](docs/argocd-gitops.md)
- [Cloudflare setup](docs/cloudflare-setup.md)
- [Hetzner infrastructure with OpenTofu](docs/hetzner-opentofu.md)
- [External Secrets and OpenBao](docs/external-secrets-openbao.md)
- [Monitoring](docs/monitoring.md) and [logging](docs/logging.md)
- [Application migration and recovery](docs/vps-app-migration.md)
- [Security monitoring and vulnerability reports](docs/security-monitoring.md)
- [Local security VM](docs/security-vm.md)
- [Operational commands and maintenance](docs/commands.md)

## Using this repository

These files describe my environment, rather than a ready-made installation for every system. Some manifests contain my public service domains and repository URLs. Addresses in documentation are examples and may differ from the live environment.

To adapt the initial server setup:

```bash
cp ansible/inventory.example.ini ansible/inventory.ini
cp ansible/group_vars/all.example.yml ansible/group_vars/all.yml
```

Edit the local copies for your own hosts and configuration. Use the relevant `.tfvars.example` files as starting points for infrastructure inputs, and explicitly set your own Cloudflare Access email. Review each runbook and command before using it, particularly migration, restore, and destroy operations.

Local inventories, credentials, Terraform state and plans, kubeconfig files, backups, and generated operational reports are excluded through `.gitignore`. Application secrets are retrieved from OpenBao at runtime. Ignore rules do not protect secrets already committed to Git.

## What this project represents

This is an evolving learning and operations project. A single-node cluster has availability limits, and I do not claim an uptime guarantee or formal standards compliance. The value for me is working through the full lifecycle: building something, operating it, finding problems, documenting decisions, and improving it.

I use AI assistance during development and troubleshooting. I review the changes, validate the results, and take responsibility for the decisions in my environment.
