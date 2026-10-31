#!/usr/bin/env bash
# OpenRouter and the Telegram approvals bot for Flowloom staging/prod: the
# values into OpenBao, the connections into each environment config file.
# Run it to see the guide: bash scripts/flowloom-connection-values.sh [env ...]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/scripts/lib/script-guide.sh"

envs=("$@")
[ "${#envs[@]}" -gt 0 ] || envs=(staging prod)

script_guide <<'GUIDE'
Flowloom: OpenRouter + Telegram approvals bot for staging/prod
--------------------------------------------------------------
Usage:  bash scripts/flowloom-connection-values.sh [env ...]   (default: staging prod)

Per environment:
  1. Asks for the OpenRouter API key (hidden; Enter reuses the one typed for
     the environment before) and the Telegram approvals bot's token (hidden;
     each environment needs its own bot: a bot has one webhook).
  2. Asks Telegram which bot the token belongs to (getMe), so the bot
     username is never typed and a wrong token stops here.
  3. Writes the values to OpenBao (JSON over stdin, never printed):
       secret/flowloom/<tenant>/<env>/openrouter          {api_key}
       secret/flowloom/<tenant>/<env>/telegram-approvals  {bot_token}
  4. Declares both connections and the approvals bot in
     kubernetes/apps/flowloom/overlays/<env>/environment.json (revision raised).

Then commit + push the homelab repo: the engine creates the connections and
sets the bot's webhook through the connector worker.
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

# The bot's username for a token (the token goes to curl on stdin, not as an argument).
bot_username() {
  printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$1" |
    curl -s --max-time 15 -K - | jq -r 'if .ok then .result.username else empty end'
}

openrouter_key=""
seen_bots=" "
# Dev's approvals bot is taken too: reusing it would move dev's webhook away.
dev_token="$(bao bao kv get -field=bot_token "secret/flowloom/${tenant}/dev/telegram-approvals" 2>/dev/null || true)"
if [ -n "${dev_token}" ]; then
  dev_bot="$(bot_username "${dev_token}")"
  [ -n "${dev_bot}" ] && seen_bots=" ${dev_bot} "
fi
unset dev_token
for env_slug in "${envs[@]}"; do
  echo
  echo "== ${env_slug}"
  env_file="${repo_root}/kubernetes/apps/flowloom/overlays/${env_slug}/environment.json"

  key="$(ask_hidden "OpenRouter API key for ${env_slug}$([ -n "${openrouter_key}" ] && echo " (Enter: same as before)")")"
  [ -z "${key}" ] && key="${openrouter_key}"
  [ -n "${key}" ] || { echo "${env_slug}: no OpenRouter key given" >&2; exit 1; }
  openrouter_key="${key}"

  token="$(ask_hidden "Telegram approvals bot token for ${env_slug}")"
  [[ "${token}" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { echo "${env_slug}: that doesn't look like a bot token (123456:ABC…)" >&2; exit 1; }
  bot="$(bot_username "${token}")"
  [ -n "${bot}" ] || { echo "${env_slug}: Telegram doesn't accept this token" >&2; exit 1; }
  case "${seen_bots}" in
    *" ${bot} "*) echo "${env_slug}: @${bot} is already used by another environment (dev included); each needs its own bot" >&2; exit 1 ;;
  esac
  seen_bots="${seen_bots}${bot} "
  echo "${env_slug}: token belongs to @${bot}"

  jq -n --arg k "${key}" '{api_key: $k}' | bao bao kv put "secret/flowloom/${tenant}/${env_slug}/openrouter" - >/dev/null
  jq -n --arg t "${token}" '{bot_token: $t}' | bao bao kv put "secret/flowloom/${tenant}/${env_slug}/telegram-approvals" - >/dev/null
  unset key token
  echo "${env_slug}: values stored in OpenBao (openrouter, telegram-approvals)"

  tmp="$(mktemp)"
  jq --arg tenant "${tenant}" --arg bot "${bot}" '
    def ensure($c): if any(.connections[]?; .name == $c.name) then . else .connections = ((.connections // []) + [$c]) end;
    .tenants = [.tenants[] | if .slug == $tenant then
      ensure({name: "openrouter", kind: "api_key", sharing: "tenant", description: "OpenRouter for the AI: chat step"})
      | ensure({name: "telegram-approvals", kind: "custom", sharing: "tenant", description: "Token of the Telegram approvals bot (bot_token)"})
      | .telegram = {connection: "telegram-approvals", bot_username: $bot}
    else . end]
  ' "${env_file}" > "${tmp}"
  jq -e --arg tenant "${tenant}" 'any(.tenants[]; .slug == $tenant)' "${tmp}" >/dev/null ||
    { rm -f "${tmp}"; echo "${env_slug}: tenant ${tenant} isn't in ${env_file}" >&2; exit 1; }
  if jq -e --slurpfile old "${env_file}" '. == $old[0]' "${tmp}" >/dev/null; then
    rm -f "${tmp}"
    echo "${env_slug}: environment.json already declares them"
  else
    jq '.revision += 1' "${tmp}" > "${env_file}"
    rm -f "${tmp}"
    echo "${env_slug}: environment.json updated, revision $(jq .revision "${env_file}")"
  fi
done
unset openrouter_key

echo
echo "Next: git diff, then commit + push the homelab repo."
