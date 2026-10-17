#!/usr/bin/env bash
# Only a database's owner may connect to it (Postgres default: every role may).
# Run it to see the guide: bash scripts/postgres-restrict-db-connect.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/scripts/lib/script-guide.sh"

script_guide <<'GUIDE'
Shared Postgres: each database only reachable by its owner
-----------------------------------------------------------
Usage:  bash scripts/postgres-restrict-db-connect.sh [database ...]
        (default: every non-template database except "postgres"; safe to re-run)

By default Postgres lets every role CONNECT to every database. Data stays
protected by table permissions, but e.g. Flowloom's dev role could log into
flowloom_prod and list its tables. This script, per database:
  REVOKE CONNECT ... FROM PUBLIC;  GRANT CONNECT ... TO <owner>
(Penpot's database is already set up like this.)

Before changing anything it shows which roles are connected to which
database. A role connected to a database it doesn't own would be locked out:
the script stops if it finds one. Apps are not restarted; open connections
stay up. Undo per database: GRANT CONNECT ON DATABASE <db> TO PUBLIC;

It asks nothing: it runs psql as the postgres superuser inside the pod.
GUIDE

kubeconfig="${repo_root}/kubeconfig"
kx() { kubectl --kubeconfig "${kubeconfig}" -n database exec -i postgres-0 -- "$@"; }

if [ "$#" -gt 0 ]; then
  dbs=("$@")
else
  mapfile -t dbs < <(kx psql -U postgres -Atc \
    "select datname from pg_database where not datistemplate and datname <> 'postgres' order by 1")
fi
[ "${#dbs[@]}" -gt 0 ] || { echo "no databases found (connection problem?)" >&2; exit 1; }

for db in "${dbs[@]}"; do
  [[ "${db}" =~ ^[a-z0-9_]+$ ]] || { echo "unexpected database name: ${db}" >&2; exit 1; }
done

# Someone connected to a database they don't own would lose access: stop.
foreign="$(kx psql -U postgres -Atc "
  select a.usename || ' -> ' || a.datname
  from pg_stat_activity a join pg_database d on d.datname = a.datname
  join pg_roles r on r.rolname = a.usename
  where a.usename <> pg_get_userbyid(d.datdba) and not r.rolsuper
  group by 1")"
if [ -n "${foreign}" ]; then
  echo "These roles use a database they don't own; not changing anything:" >&2
  echo "${foreign}" >&2
  exit 1
fi

for db in "${dbs[@]}"; do
  kx psql -U postgres -v ON_ERROR_STOP=1 -q -v db="${db}" <<'SQL'
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'db') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db', pg_get_userbyid(datdba))
FROM pg_database WHERE datname = :'db' \gexec
SQL
  echo "${db}: only its owner may connect."
done

echo
echo "Check: every app still Healthy in ArgoCD, e.g."
echo "  kubectl --kubeconfig kubeconfig -n argocd get applications"
