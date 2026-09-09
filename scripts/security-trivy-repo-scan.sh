#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
severity="${TRIVY_SEVERITY:-HIGH,CRITICAL}"

if ! command -v trivy >/dev/null 2>&1; then
  echo "trivy is not installed locally." >&2
  echo "Install it or use Trivy Operator reports in Kubernetes after Argo CD syncs trivy-operator." >&2
  exit 1
fi

trivy config \
  --severity "${severity}" \
  --exit-code 1 \
  "${repo_root}/kubernetes"

trivy fs \
  --scanners vuln,secret,misconfig \
  --severity "${severity}" \
  --exit-code 1 \
  "${repo_root}"
