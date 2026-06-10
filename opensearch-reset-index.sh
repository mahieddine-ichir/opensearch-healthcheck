#!/usr/bin/env bash
# =============================================================================
# opensearch-reset-index.sh
#
# Usage:
#   ./opensearch-reset-index.sh [OPTIONS]
#
# Options:
#   -h, --host      OpenSearch host (default: localhost)
#   -p, --port      OpenSearch port (default: 9200)
#   -u, --user      Basic auth user (optional)
#   -w, --password  Basic auth password (optional)
#   -i, --index     Base index name to delete (required)
#                   e.g. wcxss-audit-data-dev-ttl30d-write
#   --dry-run       Print curl commands without executing them
#   --help          Show this help
#
# What it does:
#   1. Deletes the index passed via -i
#   2. Creates a new dated index: <prefix>-<YYYY.MM.DD>-<00001>
#      (prefix = everything before the last '-' token of the input index name)
#   3. Re-creates the alias named after the original index, pointing to the
#      new index as the write index
# =============================================================================

set -euo pipefail

# ── defaults ──────────────────────────────────────────────────────────────────
HOST="localhost"
PORT=9200
USER=""
PASSWORD=""
INDEX_TO_DELETE=""
DRY_RUN=false

# ── helpers ───────────────────────────────────────────────────────────────────
usage() {
  sed -n '/^# Usage/,/^# =/p' "$0" | head -n -1 | sed 's/^# \{0,3\}//'
  exit 0
}

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
err()  { echo "[ERROR] $*" >&2; exit 1; }

# ── arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--host)      HOST="$2";           shift 2 ;;
    -p|--port)      PORT="$2";           shift 2 ;;
    -u|--user)      USER="$2";           shift 2 ;;
    -w|--password)  PASSWORD="$2";       shift 2 ;;
    -i|--index)     INDEX_TO_DELETE="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true;        shift   ;;
    --help)         usage ;;
    *) err "Unknown option: $1. Use --help for usage." ;;
  esac
done

[[ -z "$INDEX_TO_DELETE" ]] && err "-i / --index is required."

# ── derived names ─────────────────────────────────────────────────────────────
# Alias name  = the index name passed in  (e.g. wcxss-audit-data-dev-ttl30d-write)
ALIAS_NAME="$INDEX_TO_DELETE"

# Prefix = strip the last dash-separated token  → wcxss-audit-data-dev-ttl30d
PREFIX="${INDEX_TO_DELETE%-*}"

# Date suffix
DATE_SUFFIX=$(date +"%Y.%m.%d")

BASE_URL="https://${HOST}:${PORT}"

# Auth header (only if credentials provided)
AUTH_ARGS=()
if [[ -n "$USER" && -n "$PASSWORD" ]]; then
  AUTH_ARGS=(-u "${USER}:${PASSWORD}")
fi

# ── curl wrapper ──────────────────────────────────────────────────────────────
run_curl() {
  local method="$1"; shift
  local url="$1";    shift
  local description="$1"; shift
  local extra_args=("$@")

  local cmd=(curl -s -o /tmp/os_resp.json -w "%{http_code}"
             -X "$method"
             "${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}"
             -H "Content-Type: application/json"
             "${extra_args[@]+"${extra_args[@]}"}"
             "$url")

  if $DRY_RUN; then
    echo "[DRY-RUN] ${cmd[*]}"
    return 0
  fi

  log "$description"
  local http_code
  http_code=$("${cmd[@]}")

  local body
  body=$(cat /tmp/os_resp.json)

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
    log "→ HTTP $http_code OK"
    echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"
  else
    warn "→ HTTP $http_code"
    echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"
    err "Request failed (HTTP $http_code) — aborting."
  fi
}

# ── auto-increment: find next available sequence number ───────────────────────
# Query OpenSearch for all indices matching <prefix>-<date>-* and pick max+1.
# Falls back to 00001 if none exist or in dry-run mode.
resolve_new_index() {
  local base_pattern="${PREFIX}-${DATE_SUFFIX}-"
  local next_seq=1

  if ! $DRY_RUN; then
    # _cat/indices returns one line per index; grep our pattern, extract seq number
    local existing
    existing=$(curl -s \
      "${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}" \
      "${BASE_URL}/_cat/indices/${base_pattern}*?h=index" 2>/dev/null || true)

    if [[ -n "$existing" ]]; then
      # Extract the numeric suffix (last field after final '-'), find the max
      local max_seq
      max_seq=$(echo "$existing" \
        | grep -oE '[0-9]{5}$' \
        | sort -n \
        | tail -1)
      if [[ -n "$max_seq" ]]; then
        next_seq=$(( 10#$max_seq + 1 ))
      fi
    fi
  fi

  printf "%s%05d" "${base_pattern}" "$next_seq"
}

NEW_INDEX=$(resolve_new_index)

# ── main ──────────────────────────────────────────────────────────────────────
log "============================================================"
log "OpenSearch index reset script"
log "  Host            : ${BASE_URL}"
log "  Index to delete : ${INDEX_TO_DELETE}"
log "  New index       : ${NEW_INDEX}"
log "  Alias           : ${ALIAS_NAME}"
$DRY_RUN && log "  Mode            : DRY-RUN"
log "============================================================"

# ── Step 1: Verify the target index exists ────────────────────────────────────
# Note: HEAD + HTTP/2 causes curl to report "N bytes missing" because the server
#       returns Content-Length but no body (correct per spec). We use GET instead.
log "Step 1 — Checking index '${INDEX_TO_DELETE}' exists..."
if ! $DRY_RUN; then
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X GET \
    "${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}" \
    "${BASE_URL}/${INDEX_TO_DELETE}?pretty=false")
  if [[ "$http_code" == "200" ]]; then
    log "→ Index exists (HTTP 200)"
  elif [[ "$http_code" == "404" ]]; then
    warn "→ Index '${INDEX_TO_DELETE}' not found (HTTP 404). It may already be deleted."
    warn "   Skipping delete step and continuing..."
  else
    err "Unexpected HTTP $http_code when checking index existence."
  fi
fi

# ── Step 2: Delete the old index ──────────────────────────────────────────────
log ""
log "Step 2 — Deleting index '${INDEX_TO_DELETE}'..."
run_curl DELETE \
  "${BASE_URL}/${INDEX_TO_DELETE}" \
  "DELETE /${INDEX_TO_DELETE}"

# ── Step 3: Create the new dated index ───────────────────────────────────────
log ""
log "Step 3 — Creating index '${NEW_INDEX}'..."
run_curl PUT \
  "${BASE_URL}/${NEW_INDEX}" \
  "PUT /${NEW_INDEX}" \
  -d '{
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 1
    }
  }'

# ── Step 4: Create alias pointing to new index as write index ─────────────────
log ""
log "Step 4 — Creating alias '${ALIAS_NAME}' → '${NEW_INDEX}' (is_write_index: true)..."
run_curl POST \
  "${BASE_URL}/_aliases" \
  "POST /_aliases" \
  -d "{
    \"actions\": [
      {
        \"add\": {
          \"index\": \"${NEW_INDEX}\",
          \"alias\": \"${ALIAS_NAME}\",
          \"is_write_index\": true
        }
      }
    ]
  }"

# ── Step 5: Verify ────────────────────────────────────────────────────────────
log ""
log "Step 5 — Verifying alias..."
run_curl GET \
  "${BASE_URL}/_cat/aliases/${ALIAS_NAME}?v&h=alias,index,is_write_index" \
  "GET /_cat/aliases/${ALIAS_NAME}"

log ""
log "✅  Done. Summary:"
log "    Deleted : ${INDEX_TO_DELETE}"
log "    Created : ${NEW_INDEX}"
log "    Alias   : ${ALIAS_NAME} (write index → ${NEW_INDEX})"
