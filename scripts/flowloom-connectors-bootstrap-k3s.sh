#!/usr/bin/env bash
# Secrets for the Flowloom connector worker on k3s (kubernetes/apps/flowloom-connectors).
# Run it to see the guide: bash scripts/flowloom-connectors-bootstrap-k3s.sh [env ...] [--rotate-key | --retire-old]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/scripts/lib/script-guide.sh"

rotate=false
retire=false
envs=()
for a in "$@"; do
  case "$a" in
    --rotate-key) rotate=true ;;
    --retire-old) retire=true ;;
    *) envs+=("$a") ;;
  esac
done
[ "${#envs[@]}" -gt 0 ] || envs=(dev)
if [ "${rotate}" = true ] && [ "${retire}" = true ]; then
  echo "--rotate-key and --retire-old are two separate runs (rotate, restart the connector, then retire)." >&2
  exit 1
fi

script_guide <<'GUIDE'
Flowloom connectors on k3s: the worker's two credentials
--------------------------------------------------------
Usage:  bash scripts/flowloom-connectors-bootstrap-k3s.sh [env ...] [--rotate-key | --retire-old]   (default: dev)

Per environment, into OpenBao apps/flowloom-connectors-<env> (External Secrets
gives them to the pod; nothing secret is printed):
  1. FLOWLOOM_API_KEY: a PLATFORM worker key of that engine. Kept on re-runs.
     - Environments with an environment config file
       (kubernetes/apps/flowloom/overlays/<env>/environment.json, staging and
       prod): the key is made here, and only its sha256 goes into that file
       ("platform_keys", revision raised). The engine learns the key from the
       file: no Studio, no command in the engine pod.
     - Others (dev): made inside the engine pod, as before.
  2. OPENBAO_ROLE_ID / OPENBAO_SECRET_ID: a fresh login for the AppRole
     flowloom-connectors-<env> (made by flowloom-connectors-approle-openbao.sh):
     reads connections, issues and rotates the Microsoft app secrets.

Rotating the key (environments with the file), no downtime:
  1. --rotate-key: a new key; the file keeps the old one next to it.
     Push, wait for Argo CD, then restart the connector so it reads the new one:
     kubectl -n flowloom-connectors-<env> rollout restart deploy/flowloom-connectors
  2. --retire-old: the file keeps only the current key. Push: the engine
     revokes the old one.

Then commit + push the homelab repo; Argo CD starts flowloom-connectors-<env>.
It asks for your OpenBao admin login.
GUIDE

kubeconfig="${repo_root}/kubeconfig"
# Used by scripts/lib/openbao-login.sh as well.
namespace="openbao"
pod="openbao-0"
k() { kubectl --kubeconfig "${kubeconfig}" "$@"; }

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin
bao() { k -n "${namespace}" exec -i "${pod}" -- env "BAO_TOKEN=${BAO_TOKEN}" "$@"; }

# Writes the key's sha256 into the environment file, raising its revision
# when the file changes. $1 file, $2 sha256, $3 last 4 characters, $4 mode
# (keep: add if missing | rotate: add next to the others | retire: only this one).
declare_key() {
  local file="$1" sha="$2" hint="$3" mode="$4" name="flowloom-connectors" tmp
  [ "${mode}" = rotate ] && name="flowloom-connectors-$(date +%Y%m%d)"
  tmp="$(mktemp)"
  jq --arg name "${name}" --arg sha "${sha}" --arg hint "${hint}" --arg mode "${mode}" '
    {name: $name, key_sha256: $sha, key_hint: $hint} as $key
    | .platform_keys = (
        if $mode == "retire" then [(.platform_keys // [])[] | select(.key_sha256 == $sha)] | if . == [] then [$key] else . end
        elif any((.platform_keys // [])[]; .key_sha256 == $sha) then .platform_keys
        else (.platform_keys // []) + [$key] end)
  ' "${file}" > "${tmp}"
  if jq -e --slurpfile old "${file}" '. == $old[0]' "${tmp}" >/dev/null; then
    rm -f "${tmp}"
    return 1
  fi
  jq '.revision += 1' "${tmp}" > "${file}"
  rm -f "${tmp}"
}

for env_slug in "${envs[@]}"; do
  [[ "${env_slug}" =~ ^[a-z0-9]+$ ]] || { echo "invalid environment: ${env_slug}" >&2; exit 1; }
  path="apps/flowloom-connectors-${env_slug}"
  role="flowloom-connectors-${env_slug}"
  env_file="${repo_root}/kubernetes/apps/flowloom/overlays/${env_slug}/environment.json"

  bao bao read "auth/approle/role/${role}" >/dev/null 2>&1 || {
    echo "[${env_slug}] AppRole ${role} missing: run scripts/flowloom-connectors-approle-openbao.sh ${env_slug} first." >&2
    exit 1
  }

  # 1. platform worker key (only its last 4 characters are ever printed)
  api_key=""
  if [ "${rotate}" = false ]; then
    api_key="$(bao bao kv get -field=FLOWLOOM_API_KEY "${path}" 2>/dev/null || true)"
  fi

  if [ -f "${env_file}" ]; then
    if [ -z "${api_key}" ]; then
      [ "${retire}" = true ] && { echo "[${env_slug}] no key in ${path} to keep" >&2; exit 1; }
      api_key="flk_$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')"
      echo "[${env_slug}] new platform worker key made (…${api_key: -4})."
    else
      echo "[${env_slug}] platform worker key exists (…${api_key: -4}, kept)."
    fi

    mode=keep
    [ "${rotate}" = true ] && mode=rotate
    [ "${retire}" = true ] && mode=retire
    sha="$(printf '%s' "${api_key}" | sha256sum | cut -d' ' -f1)"
    if declare_key "${env_file}" "${sha}" "${api_key: -4}" "${mode}"; then
      echo "[${env_slug}] ${env_file#"${repo_root}"/}: platform_keys updated, revision $(jq .revision "${env_file}")."
    else
      echo "[${env_slug}] ${env_file#"${repo_root}"/}: already up to date."
    fi
  elif [ -z "${api_key}" ]; then
    engine_pod="$(k -n "flowloom-${env_slug}" get pods -l app.kubernetes.io/name=flowloom \
      --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
    k -n "flowloom-${env_slug}" exec "${engine_pod}" -c flowloom -- \
      /app/bin/flowloom eval 'Flowloom.Release.create_platform_key("flowloom-connectors", "/tmp")' | tail -1
    api_key="$(k -n "flowloom-${env_slug}" exec "${engine_pod}" -c flowloom -- sh -c \
      'f=/tmp/.flowloom-platform-worker-flowloom-connectors.env; sed -n "s/^FLOWLOOM_API_KEY=//p" "$f"; rm -f "$f"')"
    [ -n "${api_key}" ] || { echo "[${env_slug}] could not create the platform key" >&2; exit 1; }
    echo "[${env_slug}] new platform worker key created."
  else
    echo "[${env_slug}] platform worker key exists (kept; --rotate-key replaces it)."
  fi

  # 2. a fresh AppRole login for the pod
  role_id="$(bao bao read -field=role_id "auth/approle/role/${role}/role-id")"
  secret_id="$(bao bao write -f -field=secret_id "auth/approle/role/${role}/secret-id")"

  # 3. store (JSON over stdin: values never become arguments)
  jq -n --arg k "${api_key}" --arg r "${role_id}" --arg s "${secret_id}" \
    '{FLOWLOOM_API_KEY: $k, OPENBAO_ROLE_ID: $r, OPENBAO_SECRET_ID: $s}' \
    | bao bao kv put "${path}" - >/dev/null
  unset api_key role_id secret_id
  echo "[${env_slug}] stored in ${path}."
done

echo "Next: commit + push the homelab repo; Argo CD applies the environment files and starts the connectors."
