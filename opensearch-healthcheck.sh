#!/usr/bin/env bash
# =============================================================================
#  opensearch-healthcheck.sh
#  Diagnostic complet d'un cluster OpenSearch
#  Usage: ./opensearch-healthcheck.sh [OPTIONS]
#
#  Options:
#    -h, --host      URL du cluster (défaut: http://localhost:9200)
#    -u, --user      Utilisateur (optionnel)
#    -p, --pass      Mot de passe (optionnel)
#    -o, --output    Fichier de rapport (défaut: opensearch-report-<date>.txt)
#    -k, --insecure  Désactiver la vérification SSL
#    --help          Afficher cette aide
#
#  Exemples:
#    ./opensearch-healthcheck.sh -h https://my-cluster:9200 -u admin -p secret
#    ./opensearch-healthcheck.sh -h https://my-cluster:9200 -k -o rapport.txt
# =============================================================================

set -euo pipefail

# ─── Couleurs ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'

# ─── Valeurs par défaut ───────────────────────────────────────────────────────
HOST="http://localhost:9200"
USER=""
PASS=""
INSECURE=""
OUTPUT="opensearch-report-$(date +%Y%m%d-%H%M%S).txt"
ERRORS=0
WARNINGS=0

# ─── Parsing des arguments ────────────────────────────────────────────────────
usage() {
  grep '^#  ' "$0" | sed 's/^#  //'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--host)     HOST="$2";   shift 2 ;;
    -u|--user)     USER="$2";   shift 2 ;;
    -p|--pass)     PASS="$2";   shift 2 ;;
    -o|--output)   OUTPUT="$2"; shift 2 ;;
    -k|--insecure) INSECURE="-k"; shift ;;
    --help)        usage ;;
    *) echo "Option inconnue: $1"; usage ;;
  esac
done

# ─── Auth curl ───────────────────────────────────────────────────────────────
AUTH_ARGS=()
[[ -n "$USER" && -n "$PASS" ]] && AUTH_ARGS=(-u "${USER}:${PASS}")
[[ -n "$INSECURE" ]] && AUTH_ARGS+=(-k)

# ─── Helpers ─────────────────────────────────────────────────────────────────
REPORT_LINES=()

section() {
  local title="$1"
  local line="════════════════════════════════════════════════════════════════"
  echo -e "\n${BOLD}${CYAN}${line}${RESET}"
  echo -e "${BOLD}${CYAN}  $title${RESET}"
  echo -e "${BOLD}${CYAN}${line}${RESET}"
  REPORT_LINES+=("" "═══════════════════════════════════════" "  $title" "═══════════════════════════════════════")
}

subsection() {
  local title="$1"
  echo -e "\n${BOLD}${BLUE}▶ $title${RESET}"
  REPORT_LINES+=("" "▶ $title")
}

ok()   { echo -e "  ${GREEN}✔${RESET}  $*"; REPORT_LINES+=("  ✔  $*"); }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $*"; REPORT_LINES+=("  ⚠  $*"); ((WARNINGS++)) || true; }
err()  { echo -e "  ${RED}✘${RESET}  $*"; REPORT_LINES+=("  ✘  $*"); ((ERRORS++)) || true; }
info() { echo -e "  ${MAGENTA}ℹ${RESET}  $*"; REPORT_LINES+=("  ℹ  $*"); }
raw()  { echo -e "$*"; REPORT_LINES+=("$*"); }

os_get() {
  local path="$1"
  curl -s --fail --max-time 10 "${AUTH_ARGS[@]}" "${HOST}/${path}" 2>/dev/null || true
}

os_cat() {
  local path="$1"
  curl -s --fail --max-time 10 "${AUTH_ARGS[@]}" "${HOST}/_cat/${path}&format=json" 2>/dev/null || true
}

jq_or_raw() {
  # Affiche JSON formaté si jq dispo, sinon raw
  if command -v jq &>/dev/null; then
    echo "$1" | jq -r "${2:-.}"
  else
    echo "$1"
  fi
}

save_report() {
  printf '%s\n' "${REPORT_LINES[@]}" > "$OUTPUT"
  echo -e "\n${BOLD}Rapport sauvegardé : ${OUTPUT}${RESET}"
}

# ─── Vérification prérequis ──────────────────────────────────────────────────
check_prereqs() {
  section "PRÉREQUIS"
  command -v curl &>/dev/null && ok "curl disponible" || { err "curl introuvable — requis"; exit 1; }
  command -v jq   &>/dev/null && ok "jq disponible"  || warn "jq non installé — sortie JSON brute"
}

# ─── Connectivité ────────────────────────────────────────────────────────────
check_connectivity() {
  section "CONNECTIVITÉ"
  local resp
  resp=$(os_get "")
  if [[ -z "$resp" ]]; then
    err "Impossible de joindre $HOST"
    save_report
    exit 1
  fi
  ok "Cluster joignable : $HOST"
  local version
  version=$(echo "$resp" | jq -r '.version.number // "?"' 2>/dev/null || echo "?")
  local distrib
  distrib=$(echo "$resp" | jq -r '.version.distribution // "opensearch"' 2>/dev/null || echo "opensearch")
  info "Distribution : $distrib $version"
}

# ─── Cluster Health ──────────────────────────────────────────────────────────
check_cluster_health() {
  section "CLUSTER HEALTH"
  local resp
  resp=$(os_get "_cluster/health?pretty")

  local status nb_nodes active_shards unassigned relocating initializing pending_tasks
  status=$(echo "$resp"         | jq -r '.status // "unknown"')
  nb_nodes=$(echo "$resp"       | jq -r '.number_of_nodes // 0')
  active_shards=$(echo "$resp"  | jq -r '.active_shards // 0')
  unassigned=$(echo "$resp"     | jq -r '.unassigned_shards // 0')
  relocating=$(echo "$resp"     | jq -r '.relocating_shards // 0')
  initializing=$(echo "$resp"   | jq -r '.initializing_shards // 0')
  pending_tasks=$(echo "$resp"  | jq -r '.number_of_pending_tasks // 0')

  case "$status" in
    green)  ok  "Statut cluster : GREEN 🟢" ;;
    yellow) warn "Statut cluster : YELLOW 🟡 (replicas non assignés)" ;;
    red)    err  "Statut cluster : RED 🔴 (shards primaires manquants !)" ;;
    *)      warn "Statut cluster : INCONNU ($status)" ;;
  esac

  info "Nodes          : $nb_nodes"
  info "Shards actifs  : $active_shards"
  [[ "$unassigned"  -gt 0 ]] && warn "Shards UNASSIGNED   : $unassigned" || ok "Shards UNASSIGNED   : 0"
  [[ "$relocating"  -gt 0 ]] && warn "Shards RELOCATING   : $relocating" || ok "Shards RELOCATING   : 0"
  [[ "$initializing" -gt 0 ]] && warn "Shards INITIALIZING : $initializing" || ok "Shards INITIALIZING : 0"
  [[ "$pending_tasks" -gt 0 ]] && warn "Tâches en attente   : $pending_tasks" || ok "Tâches en attente   : 0"
}

# ─── Nodes ───────────────────────────────────────────────────────────────────
check_nodes() {
  section "NODES"
  subsection "Vue d'ensemble"
  local resp
  resp=$(os_cat "nodes?h=name,ip,heap.percent,ram.percent,cpu,load_1m,node.role,disk.used_percent")

  raw ""
  printf "  %-30s %-15s %5s %5s %5s %8s %10s %5s\n" \
    "NAME" "IP" "HEAP%" "RAM%" "CPU%" "LOAD_1M" "ROLE" "DISK%"
  raw "  $(printf '%.0s─' {1..85})"

  echo "$resp" | jq -r '.[] | [.name, .ip, .["heap.percent"], .["ram.percent"], .cpu, .["load_1m"], .["node.role"], .["disk.used_percent"]] | @tsv' 2>/dev/null | \
  while IFS=$'\t' read -r name ip heap ram cpu load role disk; do
    local line
    line=$(printf "  %-30s %-15s %5s %5s %5s %8s %10s %5s" "$name" "$ip" "$heap" "$ram" "$cpu" "$load" "$role" "$disk")
    raw "$line"
    # Alertes — on tronque les flottants en entier avant comparaison
    local heap_i cpu_i disk_i
    heap_i=$(echo "${heap:-0}" | cut -d. -f1)
    cpu_i=$(echo "${cpu:-0}"   | cut -d. -f1)
    disk_i=$(echo "${disk:-0}" | cut -d. -f1)
    [[ "${heap_i:-0}" -gt 85 ]] && warn "Node $name : heap élevé (${heap}%)"
    [[ "${cpu_i:-0}"  -gt 80 ]] && warn "Node $name : CPU élevé (${cpu}%)"
    [[ "${disk_i:-0}" -gt 85 ]] && warn "Node $name : disque élevé (${disk}%)"
  done

  subsection "Thread pools (rejections)"
  local tp
  tp=$(os_cat "thread_pool?h=node_name,name,active,rejected,completed,queue")
  echo "$tp" | jq -r '.[] | select(.rejected != "0" and .rejected != null) | "  ⚠  Node: \(.node_name) | Pool: \(.name) | Rejections: \(.rejected) | Queue: \(.queue)"' 2>/dev/null | \
  while IFS= read -r line; do
    raw "$line"; ((WARNINGS++)) || true
  done
  local rej_count
  rej_count=$(echo "$tp" | jq '[.[] | select(.rejected != "0" and .rejected != null)] | length' 2>/dev/null || echo 0)
  [[ "${rej_count:-0}" -eq 0 ]] && ok "Aucune rejection dans les thread pools"

  subsection "Circuit breakers"
  local cb
  cb=$(os_get "_nodes/stats/breaker")
  local tripped
  tripped=$(echo "$cb" | jq '[.nodes | to_entries[] | .value.breakers | to_entries[] | select(.value.tripped > 0)] | length' 2>/dev/null || echo 0)
  [[ "${tripped:-0}" -gt 0 ]] && err "Circuit breakers déclenchés : $tripped" || ok "Circuit breakers : aucun déclenché"

  # ── Shards par node vs limite cluster ──────────────────────────────────────
  subsection "Shards par node vs limite cluster.max_shards_per_node"

  local settings_resp max_shards_conf
  settings_resp=$(os_get "_cluster/settings?include_defaults=true&flat_settings=true")
  max_shards_conf=$(echo "$settings_resp" | jq -r '
    .persistent["cluster.max_shards_per_node"] //
    .transient["cluster.max_shards_per_node"]  //
    .defaults["cluster.max_shards_per_node"]   //
    "1000"' 2>/dev/null)
  max_shards_conf="${max_shards_conf:-1000}"
  info "Limite cluster.max_shards_per_node : $max_shards_conf"

  local shards_resp
  shards_resp=$(os_cat "shards?h=node,index,prirep,state")

  raw ""
  printf "  %-40s %10s %10s %10s %8s\n" "NODE" "SHARDS" "LIMITE" "LIBRE" "USAGE%"
  raw "  $(printf '%.0s─' {1..80})"

  echo "$shards_resp" | jq -r '
    [.[] | select(.state == "STARTED" and .node != null)]
    | group_by(.node)[]
    | {node: .[0].node, count: length}
    | [.node, (.count | tostring)]
    | @tsv' 2>/dev/null | \
  while IFS=$'\t' read -r node_name shard_count; do
    local libre pct pct_i
    libre=$(( max_shards_conf - shard_count ))
    pct=$(echo "$shard_count $max_shards_conf" | awk '{printf "%.1f", $1/$2*100}')
    pct_i=$(echo "$pct" | cut -d. -f1)
    printf "  %-40s %10s %10s %10s %7s%%\n" "$node_name" "$shard_count" "$max_shards_conf" "$libre" "$pct"
    [[ "${pct_i:-0}" -ge 90 ]] && err  "Node $node_name : shards à ${pct}% de la limite !"
    [[ "${pct_i:-0}" -ge 75 && "${pct_i:-0}" -lt 90 ]] && warn "Node $node_name : shards à ${pct}% de la limite"
  done

  # ── Espace disque par node ──────────────────────────────────────────────────
  subsection "Espace disque par node"

  local fs_resp
  fs_resp=$(os_get "_nodes/stats/fs")

  raw ""
  printf "  %-40s %12s %12s %12s %8s\n" "NODE" "TOTAL" "DISPONIBLE" "UTILISÉ" "USAGE%"
  raw "  $(printf '%.0s─' {1..88})"

  echo "$fs_resp" | jq -r '
    .nodes | to_entries[] |
    {
      name: .value.name,
      total_gb:  (.value.fs.total.total_in_bytes     / 1073741824 | . * 10 | round / 10),
      avail_gb:  (.value.fs.total.available_in_bytes / 1073741824 | . * 10 | round / 10),
      used_gb:   ((.value.fs.total.total_in_bytes - .value.fs.total.available_in_bytes) / 1073741824 | . * 10 | round / 10)
    } |
    .pct = (if .total_gb > 0 then (.used_gb / .total_gb * 100 | . * 10 | round / 10) else 0 end) |
    [.name, (.total_gb | tostring), (.avail_gb | tostring), (.used_gb | tostring), (.pct | tostring)]
    | @tsv' 2>/dev/null | \
  while IFS=$'\t' read -r name total avail used pct; do
    local pct_i
    pct_i=$(echo "${pct:-0}" | cut -d. -f1)
    printf "  %-40s %10s GB %10s GB %10s GB %7s%%\n" "$name" "$total" "$avail" "$used" "$pct"
    [[ "${pct_i:-0}" -ge 90 ]] && err  "Node $name : disque CRITIQUE (${pct}% utilisé)"
    [[ "${pct_i:-0}" -ge 80 && "${pct_i:-0}" -lt 90 ]] && warn "Node $name : disque élevé (${pct}% utilisé)"
    [[ "${pct_i:-0}" -ge 85 ]] && warn "Node $name : proche du watermark LOW (85%) → allocation shards bloquée"
    [[ "${pct_i:-0}" -ge 90 ]] && err  "Node $name : watermark HIGH (90%) dépassé → shards seront déplacés !"
    [[ "${pct_i:-0}" -ge 95 ]] && err  "Node $name : watermark FLOOD (95%) dépassé → index en READ-ONLY !"
  done

  subsection "Watermarks disque configurés"
  local wm_low wm_high wm_flood
  wm_low=$(echo "$settings_resp"   | jq -r '.defaults["cluster.routing.allocation.disk.watermark.low"]        // "85%"' 2>/dev/null)
  wm_high=$(echo "$settings_resp"  | jq -r '.defaults["cluster.routing.allocation.disk.watermark.high"]       // "90%"' 2>/dev/null)
  wm_flood=$(echo "$settings_resp" | jq -r '.defaults["cluster.routing.allocation.disk.watermark.flood_stage"] // "95%"' 2>/dev/null)
  info "Watermark LOW   (allocation bloquée) : $wm_low"
  info "Watermark HIGH  (shards déplacés)    : $wm_high"
  info "Watermark FLOOD (index read-only)    : $wm_flood"
}

# ─── Indices ─────────────────────────────────────────────────────────────────
check_indices() {
  section "INDICES"
  local resp
  resp=$(os_cat "indices?h=health,status,index,pri,rep,docs.count,docs.deleted,store.size,pri.store.size&s=index")

  local total red yellow green
  total=$(echo "$resp"  | jq 'length' 2>/dev/null || echo 0)
  red=$(echo "$resp"    | jq '[.[] | select(.health=="red")]    | length' 2>/dev/null || echo 0)
  yellow=$(echo "$resp" | jq '[.[] | select(.health=="yellow")] | length' 2>/dev/null || echo 0)
  green=$(echo "$resp"  | jq '[.[] | select(.health=="green")]  | length' 2>/dev/null || echo 0)

  info "Total indices  : $total"
  [[ "$red"    -gt 0 ]] && err  "Indices RED    : $red"    || ok "Indices RED    : 0"
  [[ "$yellow" -gt 0 ]] && warn "Indices YELLOW : $yellow" || ok "Indices YELLOW : 0"
  ok "Indices GREEN  : $green"

  subsection "Indices RED / YELLOW"
  local problem_indices
  problem_indices=$(echo "$resp" | jq -r '.[] | select(.health=="red" or .health=="yellow") | "\(.health)\t\(.index)\t\(.["docs.count"])\t\(.["store.size"])"' 2>/dev/null)
  if [[ -z "$problem_indices" ]]; then
    ok "Aucun index en état dégradé"
  else
    raw ""
    printf "  %-8s %-50s %12s %10s\n" "HEALTH" "INDEX" "DOCS" "SIZE"
    raw "  $(printf '%.0s─' {1..85})"
    echo "$problem_indices" | while IFS=$'\t' read -r health index docs size; do
      printf "  %-8s %-50s %12s %10s\n" "$health" "$index" "$docs" "$size"
    done
  fi

  subsection "Top 10 indices par taille"
  raw ""
  printf "  %-50s %12s %10s %5s %5s\n" "INDEX" "DOCS" "SIZE" "PRI" "REP"
  raw "  $(printf '%.0s─' {1..85})"
  echo "$resp" | jq -r 'sort_by(.["store.size"]) | reverse | .[:10] | .[] | [.index, .["docs.count"], .["store.size"], .pri, .rep] | @tsv' 2>/dev/null | \
  while IFS=$'\t' read -r index docs size pri rep; do
    printf "  %-50s %12s %10s %5s %5s\n" "$index" "$docs" "$size" "$pri" "$rep"
  done

  subsection "Indices fermés (closed)"
  local closed
  closed=$(os_cat "indices?h=status,index" | jq '[.[] | select(.status=="close")] | length' 2>/dev/null || echo 0)
  [[ "${closed:-0}" -gt 0 ]] && warn "Indices fermés : $closed" || ok "Indices fermés : 0"
}

# ─── Shards ──────────────────────────────────────────────────────────────────
check_shards() {
  section "SHARDS"
  local resp
  resp=$(os_cat "shards?h=index,shard,prirep,state,docs,store,node")

  local total unassigned initializing relocating
  total=$(echo "$resp"       | jq 'length' 2>/dev/null || echo 0)
  unassigned=$(echo "$resp"  | jq '[.[] | select(.state=="UNASSIGNED")]  | length' 2>/dev/null || echo 0)
  initializing=$(echo "$resp"| jq '[.[] | select(.state=="INITIALIZING")]| length' 2>/dev/null || echo 0)
  relocating=$(echo "$resp"  | jq '[.[] | select(.state=="RELOCATING")]  | length' 2>/dev/null || echo 0)

  info "Total shards        : $total"
  [[ "$unassigned"   -gt 0 ]] && err  "Shards UNASSIGNED   : $unassigned"   || ok "Shards UNASSIGNED   : 0"
  [[ "$initializing" -gt 0 ]] && warn "Shards INITIALIZING : $initializing" || ok "Shards INITIALIZING : 0"
  [[ "$relocating"   -gt 0 ]] && warn "Shards RELOCATING   : $relocating"   || ok "Shards RELOCATING   : 0"

  if [[ "$unassigned" -gt 0 ]]; then
    subsection "Détail shards UNASSIGNED"
    echo "$resp" | jq -r '.[] | select(.state=="UNASSIGNED") | "  ✘  \(.index) | shard \(.shard) | \(.prirep)"' 2>/dev/null | head -20
    subsection "Explication allocation (premier shard)"
    local explain
    explain=$(os_get "_cluster/allocation/explain?pretty" 2>/dev/null || true)
    [[ -n "$explain" ]] && raw "$(echo "$explain" | jq -r '.explanation // .error // .' 2>/dev/null | head -20)"
  fi
}

# ─── Aliases ─────────────────────────────────────────────────────────────────
check_aliases() {
  section "ALIASES"
  local resp
  resp=$(os_cat "aliases?h=alias,index,filter,routing.index")

  local total
  total=$(echo "$resp" | jq 'length' 2>/dev/null || echo 0)
  info "Total alias : $total"

  subsection "Liste des alias"
  raw ""
  printf "  %-40s %-50s %8s\n" "ALIAS" "INDEX" "FILTER"
  raw "  $(printf '%.0s─' {1..100})"
  echo "$resp" | jq -r '.[] | [.alias, .index, (.filter // "-")] | @tsv' 2>/dev/null | \
  while IFS=$'\t' read -r alias index filter; do
    printf "  %-40s %-50s %8s\n" "$alias" "$index" "$filter"
  done

  subsection "Alias pointant sur plusieurs indices"
  local multi
  multi=$(echo "$resp" | jq -r 'group_by(.alias) | .[] | select(length > 1) | "  ⚠  \(.[0].alias) → \([.[].index] | join(", "))"' 2>/dev/null)
  [[ -n "$multi" ]] && { raw "$multi"; ((WARNINGS++)) || true; } || ok "Aucun alias sur plusieurs indices"
}

# ─── Templates ───────────────────────────────────────────────────────────────
check_templates() {
  section "INDEX TEMPLATES"

  subsection "Composable templates (v2)"
  local resp
  resp=$(os_get "_index_template?pretty")
  local count
  count=$(echo "$resp" | jq '.index_templates | length' 2>/dev/null || echo "?")
  info "Composable templates : $count"
  echo "$resp" | jq -r '.index_templates[] | "  ℹ  \(.name) → patterns: \(.index_template.index_patterns | join(", "))"' 2>/dev/null | head -20

  subsection "Legacy templates (v1)"
  local resp_legacy
  resp_legacy=$(os_get "_template?pretty")
  local count_legacy
  count_legacy=$(echo "$resp_legacy" | jq 'keys | length' 2>/dev/null || echo "?")
  info "Legacy templates : $count_legacy"
  [[ "${count_legacy:-0}" -gt 0 ]] && warn "Des legacy templates sont présents — migration vers v2 recommandée"
}

# ─── ISM ─────────────────────────────────────────────────────────────────────
check_ism() {
  section "INDEX STATE MANAGEMENT (ISM)"

  local policies
  policies=$(os_get "_plugins/_ism/policies?pretty" 2>/dev/null || true)
  if [[ -z "$policies" || "$policies" == *"error"* ]]; then
    warn "ISM non disponible ou inaccessible"
    return
  fi

  local nb_policies
  nb_policies=$(echo "$policies" | jq '.policies | length' 2>/dev/null || echo 0)
  info "Politiques ISM : $nb_policies"
  echo "$policies" | jq -r '.policies[] | "  ℹ  \(.policy.policy_id)"' 2>/dev/null

  subsection "Indices en erreur ISM"
  local explain
  explain=$(os_get "_plugins/_ism/explain?pretty" 2>/dev/null || true)
  local ism_errors
  ism_errors=$(echo "$explain" | jq '[.indices | to_entries[] | select(.value.info.message? // "" | test("error|fail|exception"; "i"))] | length' 2>/dev/null || echo 0)
  [[ "${ism_errors:-0}" -gt 0 ]] && err "Indices ISM en erreur : $ism_errors" || ok "Aucun index ISM en erreur"

  subsection "Indices bloqués en transition ISM"
  local failed_transitions
  failed_transitions=$(echo "$explain" | jq -r '.indices | to_entries[] | select(.value.failed_indices? // [] | length > 0) | "  ✘  \(.key)"' 2>/dev/null)
  [[ -n "$failed_transitions" ]] && { raw "$failed_transitions"; ((ERRORS++)) || true; } || ok "Aucun index bloqué en transition"
}

# ─── Snapshots ───────────────────────────────────────────────────────────────
check_snapshots() {
  section "SNAPSHOTS"

  local repos
  repos=$(os_get "_snapshot?pretty")
  local nb_repos
  nb_repos=$(echo "$repos" | jq 'keys | length' 2>/dev/null || echo 0)
  info "Repositories : $nb_repos"

  if [[ "$nb_repos" -eq 0 ]]; then
    warn "Aucun repository de snapshot configuré !"
    return
  fi

  echo "$repos" | jq -r 'keys[]' 2>/dev/null | while read -r repo; do
    subsection "Repository : $repo"
    local snaps
    snaps=$(os_get "_snapshot/${repo}/_all?pretty" 2>/dev/null || true)
    local nb_snaps last_snap last_state last_end
    nb_snaps=$(echo "$snaps"   | jq '.snapshots | length' 2>/dev/null || echo 0)
    last_snap=$(echo "$snaps"  | jq -r '.snapshots[-1].snapshot // "?"' 2>/dev/null)
    last_state=$(echo "$snaps" | jq -r '.snapshots[-1].state // "?"' 2>/dev/null)
    last_end=$(echo "$snaps"   | jq -r '.snapshots[-1].end_time // "?"' 2>/dev/null)
    info "Total snapshots : $nb_snaps"
    info "Dernier snapshot : $last_snap (état: $last_state, fin: $last_end)"
    [[ "$last_state" == "SUCCESS" ]] && ok "Dernier snapshot réussi" || warn "Dernier snapshot non SUCCESS : $last_state"
  done
}

# ─── Pending Tasks ────────────────────────────────────────────────────────────
check_pending_tasks() {
  section "TÂCHES EN ATTENTE"
  local resp
  resp=$(os_get "_cluster/pending_tasks?pretty")
  local count
  count=$(echo "$resp" | jq '.tasks | length' 2>/dev/null || echo 0)
  [[ "${count:-0}" -gt 0 ]] && warn "Tâches en attente : $count" || ok "Aucune tâche en attente"
  [[ "${count:-0}" -gt 0 ]] && echo "$resp" | jq -r '.tasks[] | "  ⚠  [\(.priority)] \(.source)"' 2>/dev/null | head -10
}

# ─── Récapitulatif ────────────────────────────────────────────────────────────
print_summary() {
  section "RÉCAPITULATIF"
  info "Cluster   : $HOST"
  info "Date      : $(date)"
  echo ""
  [[ "$ERRORS"   -gt 0 ]] && err  "Erreurs   : $ERRORS"   || ok "Erreurs   : 0"
  [[ "$WARNINGS" -gt 0 ]] && warn "Warnings  : $WARNINGS" || ok "Warnings  : 0"
  echo ""
  if [[ "$ERRORS" -gt 0 ]]; then
    err "→ Cluster nécessite une attention immédiate"
  elif [[ "$WARNINGS" -gt 0 ]]; then
    warn "→ Cluster stable mais des points d'attention existent"
  else
    ok "→ Cluster en bonne santé 🎉"
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}${CYAN}"
  echo "  ╔═══════════════════════════════════════════════════════╗"
  echo "  ║      OpenSearch Cluster Health Check                  ║"
  echo "  ║      $(date +'%Y-%m-%d %H:%M:%S')                           ║"
  echo "  ╚═══════════════════════════════════════════════════════╝"
  echo -e "${RESET}"

  check_prereqs
  check_connectivity
  check_cluster_health
  check_nodes
  check_indices
  check_shards
  check_aliases
  check_templates
  check_ism
  check_snapshots
  check_pending_tasks
  print_summary
  save_report

  # Exit code : 0 = OK, 1 = warnings, 2 = erreurs
  [[ "$ERRORS"   -gt 0 ]] && exit 2
  [[ "$WARNINGS" -gt 0 ]] && exit 1
  exit 0
}

main "$@"