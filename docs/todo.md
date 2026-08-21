# TODO

## Backups

- Set up `rclone` for OneDrive.
- Set up `restic` encrypted backup repository on OneDrive.
- Back up laptop important files.
- Back up homelab server critical paths:
  - `/etc/rancher/k3s`
  - `/var/lib/rancher/k3s/server/db`
  - application data directories
  - Kubernetes manifests and Terraform/OpenTofu state backups
- Add scheduled backup jobs with systemd timers or cron.
- Add backup health checks and notifications.
- Practice restoring a single file, for example `~/.ssh/homelab`.
- Practice restoring a full directory.
- Run a monthly restore test.
- Later compare Hetzner Object Storage or Storage Box as a second offsite backup target.

## Monitoring And Logging

- Install kube-prometheus-stack.
- Expose Grafana at `grafana.miak-it.dev`.
- Protect Grafana with Cloudflare Access.
- Add host security monitoring for SSH/auth logs.
- Install Grafana Alloy and Loki for logs.
- Add alerts for disk, memory, CPU load, pod restarts, and backup failures.
- [x] Add a cost dashboard for electricity, hardware ownership, domains, VPS, and backup storage.
- Later connect the Hetzner VPS into the same monitoring/logging view.
