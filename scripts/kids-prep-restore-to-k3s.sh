#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/kubeconfig"
backup_dir="${repo_root}/backups/kids-prep"
data_tgz="${1:-$(ls -t "${backup_dir}"/kids-prep-data-*.tgz 2>/dev/null | head -n 1 || true)}"

if [[ -z "${data_tgz}" || ! -f "${data_tgz}" ]]; then
  echo "Missing kids-prep data archive." >&2
  exit 1
fi

kubectl --kubeconfig "${kubeconfig}" -n kids-prep scale deployment kids-prep --replicas=0 || true

kubectl --kubeconfig "${kubeconfig}" -n kids-prep apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: kids-prep-restore
spec:
  restartPolicy: Never
  securityContext:
    fsGroup: 10001
  containers:
    - name: restore
      image: busybox:1.37
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /restore-data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: kids-prep-data
YAML

kubectl --kubeconfig "${kubeconfig}" -n kids-prep wait --for=condition=Ready pod/kids-prep-restore --timeout=120s
kubectl --kubeconfig "${kubeconfig}" -n kids-prep cp "${data_tgz}" kids-prep-restore:/tmp/kids-prep-data.tgz
kubectl --kubeconfig "${kubeconfig}" -n kids-prep exec kids-prep-restore -- sh -lc '
  set -eu
  rm -rf /restore-data/*
  tar -xzf /tmp/kids-prep-data.tgz -C /restore-data
  chown -R 10001:10001 /restore-data
  rm -f /tmp/kids-prep-data.tgz
'
kubectl --kubeconfig "${kubeconfig}" -n kids-prep delete pod kids-prep-restore

kubectl --kubeconfig "${kubeconfig}" -n kids-prep scale deployment kids-prep --replicas=1
kubectl --kubeconfig "${kubeconfig}" -n kids-prep rollout status deployment/kids-prep --timeout=300s
kubectl --kubeconfig "${kubeconfig}" -n kids-prep get pods
