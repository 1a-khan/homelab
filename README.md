# Homelab Production Kubernetes

Single-node production-style k3s platform behind an LTE router, exposed through Cloudflare Tunnel.

## First Milestone

1. Bootstrap the mini PC with Ansible.
2. Install k3s.
3. Verify `kubectl` access from the laptop.
4. Deploy a small test app.
5. Expose the test app through Cloudflare Tunnel.

## Tool Boundaries

- Ansible configures the Ubuntu server.
- Terraform manages Cloudflare resources.
- Kubernetes manifests and Helm manage workloads inside k3s.

