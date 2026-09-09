# Security Monitoring

## Roles

- Wazuh runs on `local-svr` for continuous host security, package/CVE visibility,
  login events, and file integrity signals.
- Trivy Operator runs in k3s for Kubernetes workload vulnerability,
  misconfiguration, secret, RBAC, and outdated API reports.
- Renovate watches repo dependencies and opens pull requests for old images,
  Helm charts, and OpenTofu providers.
- OpenVAS is paused for now. Add it later only for LAN/public network scans.

## Wazuh Manager And Local Agent

Wazuh is deployed with the official single-node Docker Compose stack under:

```text
/opt/wazuh-docker/single-node
```

Run:

```bash
cd /home/dev/Desktop/local-svr/homelab/ansible
ansible-playbook -i inventory.ini playbooks/60-wazuh-local-svr.yml
```

Dashboard:

```text
https://192.168.8.140:9443
```

The official Docker stack starts with default credentials. Rotate the Wazuh
passwords immediately after the first successful login.

## Laptop Wazuh Agent

Install the Wazuh agent on this laptop and enroll it into the local Wazuh manager:

```bash
cd /home/dev/Desktop/local-svr/homelab/ansible
ansible-playbook -i inventory.localhost.ini playbooks/65-wazuh-agent-laptop.yml --ask-become-pass
```

The laptop agent name is `dev-laptop`, and it reports to `192.168.8.140`.

## Trivy Operator

Trivy Operator is defined as an Argo CD Helm application in:

```text
kubernetes/platform/argocd/applications/platform.yml
kubernetes/platform/trivy-operator
```

After pushing to `main`, refresh Argo CD:

```bash
kubectl --kubeconfig kubeconfig -n argocd annotate application homelab-apps \
  argocd.argoproj.io/refresh=hard --overwrite
```

Check reports:

```bash
kubectl --kubeconfig kubeconfig get vulnerabilityreports -A
kubectl --kubeconfig kubeconfig get configauditreports -A
kubectl --kubeconfig kubeconfig get exposedsecretreports -A
kubectl --kubeconfig kubeconfig get rbacassessmentreports -A
```

## Local Trivy Repo Scan

Optional local scan:

```bash
scripts/security-trivy-repo-scan.sh
```

## Wazuh Security Briefing

Generate a Markdown briefing from Wazuh agents, SCA/CIS results,
vulnerability inventory, and alert summaries:

```bash
cd /home/dev/Desktop/local-svr/homelab
scripts/security-wazuh-report.sh
```

Reports are saved under:

```text
security-reports/
```

Use the newest report as the input for remediation planning. The report includes
an AI planning prompt at the bottom so we can turn Wazuh findings into practical
Ansible, OpenTofu, Kubernetes, backup, and maintenance-window tasks.

Recommended rhythm:

```text
Daily:   glance at Wazuh dashboard for Critical/High changes
Weekly:  generate Wazuh security briefing
Monthly: review remediation plan and run safe maintenance playbook
After updates: generate a new report and compare vulnerability counts
```

## Sources

- Wazuh Docker deployment:
  https://documentation.wazuh.com/current/deployment-options/docker/wazuh-container.html
- Wazuh Linux agent deployment:
  https://documentation.wazuh.com/current/installation-guide/wazuh-agent/wazuh-agent-package-linux.html
- Trivy Operator:
  https://aquasecurity.github.io/trivy-operator/
