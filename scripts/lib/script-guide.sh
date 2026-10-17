#!/usr/bin/env bash
# Helpers so a script explains itself before doing anything:
#
#   script_guide <<'GUIDE'
#   What it does / what it asks / what happens after
#   GUIDE
#     Prints the guide and waits for Enter (Ctrl+C aborts). Skipped when there
#     is no terminal or with GUIDE=off, e.g. GUIDE=off bash scripts/x.sh ...
#
#   ask_value VAR "Prompt" [default] [regex]
#     Leaves VAR alone if it is already set (from an argument); otherwise
#     asks for it, offering the default, and re-asks until it matches regex.

script_guide() {
  local text
  text="$(cat)"
  printf '\n%s\n\n' "${text}"
  # stdin is the guide text here, so talk to the terminal directly.
  if [ "${GUIDE:-on}" != "off" ] && { : </dev/tty; } 2>/dev/null; then
    printf 'Press Enter to continue (Ctrl+C to abort) '
    IFS= read -r _ </dev/tty
    printf '\n'
  fi
}

ask_value() {
  local var="$1" prompt="$2" default="${3:-}" pattern="${4:-}" value
  value="${!var:-}"
  while :; do
    if [ -z "${value}" ]; then
      if [ ! -t 0 ]; then
        echo "${prompt}: missing (pass it as an argument)" >&2
        exit 1
      fi
      if [ -n "${default}" ]; then
        printf '%s [%s]: ' "${prompt}" "${default}"
      else
        printf '%s: ' "${prompt}"
      fi
      IFS= read -r value
      value="${value:-${default}}"
    fi
    if [ -n "${value}" ] && { [ -z "${pattern}" ] || [[ "${value}" =~ ${pattern} ]]; }; then
      printf -v "${var}" '%s' "${value}"
      return 0
    fi
    echo "  invalid ${prompt,,}: '${value}'" >&2
    value=""
    [ -t 0 ] || exit 1
  done
}
