#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ansible_dir="${repo_root}/ansible"
inventory="${WAZUH_ANSIBLE_INVENTORY:-inventory.ini}"
target="${WAZUH_ANSIBLE_TARGET:-k3s_servers}"
report_dir="${WAZUH_REPORT_DIR:-${repo_root}/security-reports}"
report_id="$(date +%Y%m%dT%H%M%S%z)"
report_path="${report_dir}/wazuh-security-${report_id}.md"
json_bundle="$(mktemp)"

indexer_user="${WAZUH_INDEXER_USER:-admin}"
indexer_password="${WAZUH_INDEXER_PASSWORD:-SecretPassword}"
api_user="${WAZUH_API_USER:-wazuh-wui}"
api_password="${WAZUH_API_PASSWORD:-MyS3cr37P450r.*-}"

mkdir -p "${report_dir}"
trap 'rm -f "${json_bundle}"' EXIT

run_remote() {
  (cd "${ansible_dir}" && ansible -i "${inventory}" "${target}" -m shell -a "$1") \
    | awk 'found { print } / \| (CHANGED|SUCCESS) \| rc=0 >>$/ { found=1 }'
}

indexer_search() {
  local index="$1"
  local query="$2"

  run_remote "docker exec single-node-wazuh.dashboard-1 sh -lc 'cat > /tmp/wazuh-report-query.json <<'\\''JSON'\\''
${query}
JSON
curl -k -sS -u \"${indexer_user}:${indexer_password}\" -H \"Content-Type: application/json\" \"https://wazuh.indexer:9200/${index}/_search?pretty\" -d @/tmp/wazuh-report-query.json
rm -f /tmp/wazuh-report-query.json'"
}

api_get() {
  local path="$1"

  run_remote "docker exec single-node-wazuh.dashboard-1 sh -lc 'TOKEN=\$(curl -k -sS -u \"${api_user}:${api_password}\" \"https://wazuh.manager:55000/security/user/authenticate?raw=true\"); curl -k -sS -H \"Authorization: Bearer \$TOKEN\" \"https://wazuh.manager:55000${path}\"'"
}

agents_json="$(api_get "/agents?pretty=true")"
agent_ids="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(i.get("id","") for i in d.get("data",{}).get("affected_items",[]) if i.get("id") != "000"))' <<<"${agents_json}")"
sca_json='{"data":{"affected_items":[]}}'
for agent_id in ${agent_ids}; do
  agent_sca_json="$(api_get "/sca/${agent_id}?pretty=true")"
  agent_sca_json="$(python3 -c 'import json,sys; d=json.load(sys.stdin); [i.__setitem__("agent_id", sys.argv[1]) for i in d.get("data",{}).get("affected_items",[])]; print(json.dumps(d))' "${agent_id}" <<<"${agent_sca_json}")"
  sca_json="$(python3 -c 'import json,sys; base=json.loads(sys.argv[1]); extra=json.load(sys.stdin); base.setdefault("data",{}).setdefault("affected_items",[]).extend(extra.get("data",{}).get("affected_items",[])); print(json.dumps(base))' "${sca_json}" <<<"${agent_sca_json}")"
done

vuln_summary_json="$(indexer_search "wazuh-states-vulnerabilities-*" '{
  "size": 0,
  "aggs": {
    "severity": { "terms": { "field": "vulnerability.severity", "size": 10 } },
    "agents": { "terms": { "field": "agent.name", "size": 20 } },
    "packages": { "terms": { "field": "package.name", "size": 20 } }
  }
}')"

top_vulns_json="$(indexer_search "wazuh-states-vulnerabilities-*" '{
  "size": 20,
  "sort": [
    { "vulnerability.score.base": { "order": "desc", "missing": "_last" } },
    { "vulnerability.detected_at": { "order": "desc" } }
  ],
  "_source": [
    "agent.name",
    "host.os.full",
    "package.name",
    "package.version",
    "vulnerability.id",
    "vulnerability.severity",
    "vulnerability.score.base",
    "vulnerability.detected_at",
    "vulnerability.reference"
  ]
}')"

alert_summary_json="$(indexer_search "wazuh-alerts-4.x-*" '{
  "size": 0,
  "aggs": {
    "rules": {
      "terms": { "field": "rule.id", "size": 20 },
      "aggs": {
        "sample": {
          "top_hits": {
            "size": 1,
            "_source": ["rule.description", "rule.level", "agent.name"]
          }
        }
      }
    }
  }
}')"

cat > "${json_bundle}" <<EOF
${agents_json}
---WAZUH-REPORT-BLOCK---
${sca_json}
---WAZUH-REPORT-BLOCK---
${vuln_summary_json}
---WAZUH-REPORT-BLOCK---
${top_vulns_json}
---WAZUH-REPORT-BLOCK---
${alert_summary_json}
EOF

python3 - "$report_path" "${json_bundle}" <<'PY'
import datetime
import json
import sys

report_path = sys.argv[1]
bundle_path = sys.argv[2]
with open(bundle_path, "r", encoding="utf-8") as f:
    blocks = f.read().split("---WAZUH-REPORT-BLOCK---")
if len(blocks) != 5:
    raise SystemExit("Could not parse Wazuh query output.")

def load(block):
    block = block.strip()
    if not block:
        return {}
    return json.loads(block)

agents, sca, vuln_summary, top_vulns, alert_summary = [load(block) for block in blocks]

def buckets(agg, name):
    return agg.get("aggregations", {}).get(name, {}).get("buckets", [])

def md_table(headers, rows):
    if not rows:
        return "_No data._\n"
    out = ["| " + " | ".join(headers) + " |", "| " + " | ".join(["---"] * len(headers)) + " |"]
    out.extend("| " + " | ".join(str(cell).replace("\n", " ") for cell in row) + " |" for row in rows)
    return "\n".join(out) + "\n"

agent_items = agents.get("data", {}).get("affected_items", [])
sca_items = sca.get("data", {}).get("affected_items", [])
vuln_total = vuln_summary.get("hits", {}).get("total", {}).get("value", 0)
top_hits = top_vulns.get("hits", {}).get("hits", [])
alert_buckets = buckets(alert_summary, "rules")

agent_rows = [
    [
        item.get("id", ""),
        item.get("name", ""),
        item.get("ip", ""),
        item.get("status", ""),
        item.get("version", ""),
        item.get("os", {}).get("name", ""),
    ]
    for item in agent_items
]

sca_rows = [
    [
        item.get("agent_id", ""),
        item.get("policy_id", ""),
        item.get("name", ""),
        item.get("score", ""),
        item.get("pass", ""),
        item.get("fail", ""),
        item.get("invalid", ""),
        item.get("end_scan", ""),
    ]
    for item in sca_items
]

severity_rows = [[b.get("key", ""), b.get("doc_count", 0)] for b in buckets(vuln_summary, "severity")]
vuln_agent_rows = [[b.get("key", ""), b.get("doc_count", 0)] for b in buckets(vuln_summary, "agents")]
package_rows = [[b.get("key", ""), b.get("doc_count", 0)] for b in buckets(vuln_summary, "packages")]

top_vuln_rows = []
for hit in top_hits:
    src = hit.get("_source", {})
    vuln = src.get("vulnerability", {})
    pkg = src.get("package", {})
    top_vuln_rows.append([
        src.get("agent", {}).get("name", ""),
        vuln.get("severity", ""),
        vuln.get("score", {}).get("base", ""),
        vuln.get("id", ""),
        pkg.get("name", ""),
        pkg.get("version", ""),
        vuln.get("detected_at", ""),
    ])

alert_rows = []
for bucket in alert_buckets:
    sample_hits = bucket.get("sample", {}).get("hits", {}).get("hits", [])
    src = sample_hits[0].get("_source", {}) if sample_hits else {}
    rule = src.get("rule", {})
    alert_rows.append([
        bucket.get("key", ""),
        bucket.get("doc_count", 0),
        rule.get("level", ""),
        rule.get("description", ""),
        src.get("agent", {}).get("name", ""),
    ])

now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
critical = next((b.get("doc_count", 0) for b in buckets(vuln_summary, "severity") if b.get("key") == "Critical"), 0)
high = next((b.get("doc_count", 0) for b in buckets(vuln_summary, "severity") if b.get("key") == "High"), 0)

content = f"""# Wazuh Security Briefing

Generated: `{now}`

## Executive Summary

- Monitored agents: `{len(agent_items)}`
- Vulnerability records: `{vuln_total}`
- Critical vulnerabilities: `{critical}`
- High vulnerabilities: `{high}`

## Agents

{md_table(["ID", "Name", "IP", "Status", "Version", "OS"], agent_rows)}

## SCA / CIS Summary

{md_table(["Agent", "Policy", "Name", "Score", "Pass", "Fail", "Invalid", "Last scan"], sca_rows)}

## Vulnerabilities By Severity

{md_table(["Severity", "Count"], severity_rows)}

## Vulnerabilities By Agent

{md_table(["Agent", "Count"], vuln_agent_rows)}

## Top Affected Packages

{md_table(["Package", "Count"], package_rows)}

## Highest Scored Vulnerabilities

{md_table(["Agent", "Severity", "Score", "CVE", "Package", "Version", "Detected"], top_vuln_rows)}

## Top Alert Rules

{md_table(["Rule ID", "Count", "Level", "Description", "Sample agent"], alert_rows)}

## AI Planning Prompt

Use this report to create a practical remediation plan for a small homelab/company environment.

Prioritize:

1. Critical and High vulnerabilities that have available OS/package updates.
2. Problems affecting internet-facing services, authentication, SSH, TLS, Kubernetes, or secrets.
3. Noisy alerts that indicate resource pressure, dropped events, or failed monitoring.
4. Low-risk hardening tasks that improve CIS/SCA score without breaking production apps.

For each recommendation, include:

- Why it matters.
- Risk if ignored.
- Exact verification command.
- Suggested Ansible/OpenTofu/Kubernetes change.
- Whether it needs a maintenance window or reboot.

Avoid recommending destructive actions unless backup/restore has been verified first.
"""

with open(report_path, "w", encoding="utf-8") as f:
    f.write(content)

print(report_path)
PY

echo "Wazuh security report written to ${report_path}"
