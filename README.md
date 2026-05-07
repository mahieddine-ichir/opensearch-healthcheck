# OpenSearch Cluster Health Check

A comprehensive Bash diagnostic script for OpenSearch clusters. Runs a full health audit and produces a color-coded terminal report plus a saved text file.

## Features

- **Cluster health** — status (green/yellow/red), shard counts, pending tasks
- **Nodes** — heap, CPU, RAM, disk usage, thread pool rejections, circuit breakers, shards-per-node vs limit, disk watermarks
- **Indices** — red/yellow indices, top 10 by size, closed indices
- **Shards** — unassigned/initializing/relocating shards with allocation explain
- **Aliases** — list of all aliases, detection of aliases pointing to multiple indices
- **Index templates** — composable (v2) and legacy (v1) templates
- **ISM policies** — policy list, indices in error or stuck in transition
- **Snapshots** — repository list, last snapshot status per repository
- **Pending tasks** — cluster-level task queue
- **Summary** — error/warning counts with exit code for CI integration

## Requirements

| Tool | Required |
|------|----------|
| `curl` | Yes |
| `jq`  | No (raw JSON output if absent) |

## Usage

```bash
./opensearch-healthcheck.sh [OPTIONS]
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-h`, `--host` | Cluster URL | `http://localhost:9200` |
| `-u`, `--user` | Username | _(none)_ |
| `-p`, `--pass` | Password | _(none)_ |
| `-o`, `--output` | Report file path | `opensearch-report-<date>.txt` |
| `-k`, `--insecure` | Disable SSL verification | _(off)_ |
| `--help` | Show help | |

### Examples

```bash
# Local cluster, no auth
./opensearch-healthcheck.sh

# Remote cluster with basic auth
./opensearch-healthcheck.sh -h https://my-cluster:9200 -u admin -p secret

# Skip SSL verification, custom report file
./opensearch-healthcheck.sh -h https://my-cluster:9200 -k -o report.txt

# AWS OpenSearch (IAM auth handled externally via proxy or signed requests)
./opensearch-healthcheck.sh -h https://my-domain.eu-west-1.es.amazonaws.com
```

## Output

The script prints a color-coded report to the terminal and saves a plain-text copy to the output file.

```
  ╔═══════════════════════════════════════════════════════╗
  ║      OpenSearch Cluster Health Check                  ║
  ║      2024-01-15 10:23:45                              ║
  ╚═══════════════════════════════════════════════════════╝

════════════════════════════════════════════════════════════════
  CLUSTER HEALTH
════════════════════════════════════════════════════════════════
  ✔  Statut cluster : GREEN 🟢
  ℹ  Nodes          : 3
  ✔  Shards UNASSIGNED   : 0
  ...
```

Icons used:

| Icon | Meaning |
|------|---------|
| `✔`  | OK |
| `⚠`  | Warning |
| `✘`  | Error |
| `ℹ`  | Info |

## Exit Codes

| Code | Meaning |
|------|---------|
| `0`  | Cluster healthy, no warnings |
| `1`  | Warnings present |
| `2`  | Errors present (requires immediate attention) |

Exit codes make the script suitable for use in CI/CD pipelines or monitoring scripts:

```bash
./opensearch-healthcheck.sh -h https://my-cluster:9200 -u admin -p secret
if [[ $? -eq 2 ]]; then
  echo "OpenSearch cluster has critical errors!"
fi
```

## Installation

```bash
git clone https://github.com/your-username/opensearch-health.git
cd opensearch-health
chmod +x opensearch-healthcheck.sh
./opensearch-healthcheck.sh --help
```

## License

MIT
