#!/usr/bin/env bash
# Mailjet for Flowloom: each environment's keys and sender into OpenBao, and
# (staging/prod) the mail connection into its environment config file.
# Run it to see the guide: bash scripts/flowloom-mail-values.sh [env ...]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/scripts/lib/script-guide.sh"

envs=("$@")
[ "${#envs[@]}" -gt 0 ] || envs=(dev staging prod)

script_guide <<'GUIDE'
Flowloom: Mailjet keys and sender per environment
-------------------------------------------------
Usage:  bash scripts/flowloom-mail-values.sh [env ...]   (default: dev staging prod)

Per environment:
  1. Asks for the Mailjet API key and secret key (hidden; Enter reuses the
     ones typed for the environment before), and the sender, e.g.
     "Flowloom Staging <staging-flowloom@mail.miak-it.com>".
  2. Asks Mailjet whether it accepts the keys, and warns if the sender isn't
     one of the account's active senders (or on an active sender domain).
  3. Writes the value to OpenBao (JSON over stdin, never printed):
       secret/flowloom/<tenant>/<env>/mail  {provider: mailjet, api_key, secret_key, from}
  4. staging/prod: declares the connection "mail" (kind mailjet) and makes it
     the environment's mail connection in
     kubernetes/apps/flowloom/overlays/<env>/environment.json (revision raised).
     dev has no config file: create the connection "mail" (Mailjet) in dev's
     Studio under Connections, then choose it under Task notifications.

Only after staging/prod run an engine that knows mail connections (the
release with "Sent emails"): an older engine refuses the whole file.
Then commit + push the homelab repo.
It asks for your OpenBao admin login.
GUIDE

kubeconfig="${repo_root}/kubeconfig"
# Used by scripts/lib/openbao-login.sh as well.
namespace="openbao"
pod="openbao-0"

tenant="${FLOWLOOM_TENANT:-}"
ask_value tenant "Flowloom tenant slug" "miak-it" '^[a-z0-9-]+$'

for env_slug in "${envs[@]}"; do
  [[ "${env_slug}" =~ ^[a-z0-9]+$ ]] || { echo "invalid environment: ${env_slug}" >&2; exit 1; }
  [ "${env_slug}" = dev ] && continue
  [ -f "${repo_root}/kubernetes/apps/flowloom/overlays/${env_slug}/environment.json" ] ||
    { echo "${env_slug}: no environment.json (run flowloom-connectors-bootstrap-k3s.sh first)" >&2; exit 1; }
done

source "${repo_root}/scripts/lib/openbao-login.sh"
openbao_login_admin
bao() { kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec -i "${pod}" -- env "BAO_TOKEN=${BAO_TOKEN}" "$@"; }

ask_hidden() {
  local prompt="$1" value
  printf '%s: ' "${prompt}" >/dev/tty
  IFS= read -rs value </dev/tty
  printf '\n' >/dev/tty
  printf '%s' "${value}"
}

# Mailjet's senders for a key pair (the keys go to curl on stdin, not as an
# argument); empty when Mailjet doesn't accept the keys.
mailjet_senders() {
  printf 'user = "%s:%s"\nurl = "https://api.mailjet.com/v3/REST/sender?Limit=1000"\n' "$1" "$2" |
    curl -s --max-time 20 -K - | jq -c 'select(.Data != null) | [.Data[] | {Email, Status}]' 2>/dev/null || true
}

default_sender() {
  case "$1" in
    prod) echo "Flowloom <flowloom@mail.miak-it.com>" ;;
    *) echo "Flowloom $(tr '[:lower:]' '[:upper:]' <<<"${1:0:1}")${1:1} <$1-flowloom@mail.miak-it.com>" ;;
  esac
}

api_key=""
secret_key=""
for env_slug in "${envs[@]}"; do
  echo
  echo "== ${env_slug}"

  key="$(ask_hidden "Mailjet API key for ${env_slug}$([ -n "${api_key}" ] && echo " (Enter: same as before)")")"
  [ -z "${key}" ] && key="${api_key}"
  secret="$(ask_hidden "Mailjet secret key for ${env_slug}$([ -n "${secret_key}" ] && echo " (Enter: same as before)")")"
  [ -z "${secret}" ] && secret="${secret_key}"
  [ -n "${key}" ] && [ -n "${secret}" ] || { echo "${env_slug}: no Mailjet keys given" >&2; exit 1; }
  api_key="${key}"
  secret_key="${secret}"

  from=""
  ask_value from "Sender for ${env_slug}" "$(default_sender "${env_slug}")" '^[^<>]*<?[^@<> ]+@[^@<> ]+\.[^@<> ]+>?$'
  address="$(sed -E 's/.*<([^>]+)>.*/\1/' <<<"${from}")"

  senders="$(mailjet_senders "${key}" "${secret}")"
  [ -n "${senders}" ] || { echo "${env_slug}: Mailjet doesn't accept these keys" >&2; exit 1; }
  echo "${env_slug}: Mailjet accepts the keys"
  if jq -e --arg a "${address,,}" --arg d "*@${address#*@}" \
      'any(.[]; (.Status == "Active") and ((.Email | ascii_downcase) == $a or (.Email | ascii_downcase) == ($d | ascii_downcase)))' \
      <<<"${senders}" >/dev/null; then
    echo "${env_slug}: ${address} is an active sender"
  else
    echo "${env_slug}: WARNING: ${address} isn't an active Mailjet sender (or sender domain) yet; Mailjet will refuse its emails until it is" >&2
  fi

  jq -n --arg k "${key}" --arg s "${secret}" --arg f "${from}" \
    '{provider: "mailjet", api_key: $k, secret_key: $s, from: $f}' |
    bao bao kv put "secret/flowloom/${tenant}/${env_slug}/mail" - >/dev/null
  unset key secret senders
  echo "${env_slug}: value stored in OpenBao (mail)"

  if [ "${env_slug}" = dev ]; then
    echo "dev: in dev's Studio: Connections -> New: name \"mail\", kind Mailjet (its value is set now),"
    echo "     then Task notifications -> Mail server: choose \"mail\"."
    continue
  fi

  env_file="${repo_root}/kubernetes/apps/flowloom/overlays/${env_slug}/environment.json"
  tmp="$(mktemp)"
  jq --arg tenant "${tenant}" '
    def ensure($c): if any(.connections[]?; .name == $c.name) then . else .connections = ((.connections // []) + [$c]) end;
    .tenants = [.tenants[] | if .slug == $tenant then
      ensure({name: "mail", kind: "mailjet", sharing: "tenant", description: "Mailjet: task emails and Email: send steps"})
      | .email = {connection: "mail"}
    else . end]
  ' "${env_file}" > "${tmp}"
  jq -e --arg tenant "${tenant}" 'any(.tenants[]; .slug == $tenant)' "${tmp}" >/dev/null ||
    { rm -f "${tmp}"; echo "${env_slug}: tenant ${tenant} isn't in ${env_file}" >&2; exit 1; }
  if jq -e --slurpfile old "${env_file}" '. == $old[0]' "${tmp}" >/dev/null; then
    rm -f "${tmp}"
    echo "${env_slug}: environment.json already declares it"
  else
    jq '.revision += 1' "${tmp}" > "${env_file}"
    rm -f "${tmp}"
    echo "${env_slug}: environment.json updated, revision $(jq .revision "${env_file}")"
  fi
done
unset api_key secret_key

echo
echo "Next: git diff, then commit + push the homelab repo."
