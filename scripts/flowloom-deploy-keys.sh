#!/usr/bin/env bash
# Deploy keys for the Flowloom processes pipeline (repo flowloom-processes):
# one deploy-scope key per engine, declared in its environment config file,
# kept in OpenBao and handed to GitHub as a repo secret.
# Run it to see the guide: bash scripts/flowloom-deploy-keys.sh [env ...] [--rotate-key]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/scripts/lib/script-guide.sh"

rotate=false
envs=()
for a in "$@"; do
  if [ "$a" = "--rotate-key" ]; then rotate=true; else envs+=("$a"); fi
done
[ "${#envs[@]}" -gt 0 ] || envs=(staging prod)

script_guide <<'GUIDE'
Flowloom processes pipeline: a deploy key per engine
----------------------------------------------------
Usage:  bash scripts/flowloom-deploy-keys.sh [env ...] [--rotate-key]   (default: staging prod)

Per environment:
  1. A deploy-scope API key (it can only deploy process bundles, nothing else).
     Kept in OpenBao apps/flowloom-processes-<env>; re-runs keep it,
     --rotate-key makes a new one (the old one is revoked once the file applies).
  2. Only its sha256 goes into kubernetes/apps/flowloom/overlays/<env>/environment.json
     (tenant's api_keys "flowloom-processes-deploy", revision raised).
  3. The key itself goes to GitHub as secret FLOWLOOM_<ENV>_DEPLOY_KEY of the
     processes repo (gh secret set, from stdin).

Needs: gh logged in with admin rights on the processes repo, which must exist.
Then commit + push the homelab repo.
It asks for your OpenBao admin login.
GUIDE

kubeconfig="${repo_root}/kubeconfig"
# Used by scripts/lib/openbao-login.sh as well.
namespace="openbao"
pod="openbao-0"

tenant="${FLOWLOOM_TENANT:-}"
ask_value tenant "Flowloom tenant slug" "miak-it" '^[a-z0-9-]+$'
processes_repo="${FLOWLOOM_PROCESSES_REPO:-}"
ask_value processes_repo "GitHub repo of the processes pipeline" "1a-khan/flowloom-processes" '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'

gh repo view "${processes_repo}" >/dev/null 2>&1 ||
  { echo "${processes_repo}: not found (create it first, see its README)" >&2; exit 1; }
for env_slug in "${envs[@]}"; do
  [[ "${env_slug}" =~ ^[a-z0-9]+$ ]] || { echo "invalid environment: ${env_slug}" >&2; exit 1; }
  [ -f "${repo_root}/kubernetes/apps/flowloom/overlays/${env_slug}/environment.json" ] ||
    { echo "${env_slug}: no environment.json" >&2; exit 1; }
done

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin
bao() { kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- env "BAO_TOKEN=${BAO_TOKEN}" "$@"; }

for env_slug in "${envs[@]}"; do
  path="apps/flowloom-processes-${env_slug}"
  env_file="${repo_root}/kubernetes/apps/flowloom/overlays/${env_slug}/environment.json"
  secret_name="FLOWLOOM_${env_slug^^}_DEPLOY_KEY"

  key=""
  [ "${rotate}" = false ] && key="$(bao bao kv get -field=FLOWLOOM_DEPLOY_KEY "${path}" 2>/dev/null || true)"
  if [ -z "${key}" ]; then
    key="flk_$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')"
    jq -n --arg k "${key}" '{FLOWLOOM_DEPLOY_KEY: $k}' | bao bao kv put "${path}" - >/dev/null
    echo "[${env_slug}] new deploy key (…${key: -4}) stored in ${path}."
  else
    echo "[${env_slug}] deploy key exists (…${key: -4}, kept)."
  fi

  sha="$(printf '%s' "${key}" | sha256sum | cut -d' ' -f1)"
  tmp="$(mktemp)"
  jq --arg tenant "${tenant}" --arg sha "${sha}" --arg hint "${key: -4}" '
    .tenants = [.tenants[] | if .slug == $tenant then
      .api_keys = ([(.api_keys // [])[] | select(.name != "flowloom-processes-deploy")]
                   + [{name: "flowloom-processes-deploy", scopes: ["deploy"], key_sha256: $sha, key_hint: $hint}])
    else . end]
  ' "${env_file}" > "${tmp}"
  jq -e --arg tenant "${tenant}" 'any(.tenants[]; .slug == $tenant)' "${tmp}" >/dev/null ||
    { rm -f "${tmp}"; echo "[${env_slug}] tenant ${tenant} isn't in ${env_file}" >&2; exit 1; }
  # Same key already declared (key order aside): nothing to change.
  if jq -e --slurpfile old "${env_file}" '
       def norm: .tenants |= map(.api_keys |= ((. // []) | sort_by(.name)));
       (. | norm) == ($old[0] | norm)' "${tmp}" >/dev/null; then
    rm -f "${tmp}"
    echo "[${env_slug}] environment.json already declares it."
  else
    jq '.revision += 1' "${tmp}" > "${env_file}"
    rm -f "${tmp}"
    echo "[${env_slug}] environment.json updated, revision $(jq .revision "${env_file}")."
  fi

  printf '%s' "${key}" | gh secret set "${secret_name}" --repo "${processes_repo}" >/dev/null
  unset key
  echo "[${env_slug}] GitHub secret ${secret_name} set on ${processes_repo}."
done

echo "Next: commit + push the homelab repo (the engines learn the keys from their files)."
