#!/usr/bin/env bash
# cnpg-chaos-test.sh — Automated failover chaos test for CloudNativePG
# Usage: ./cnpg-chaos-test.sh [--cluster my-pg-cluster] [--namespace default] [--skip-write] [--skip-kill]
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CLUSTER="${CLUSTER:-my-pg-cluster}"
NAMESPACE="${NAMESPACE:-default}"
DB_NAME="${DB_NAME:-app_db}"
DB_USER="${DB_USER:-app_user}"
TABLE="${TABLE:-chaos_test}"
FAILOVER_TIMEOUT="${FAILOVER_TIMEOUT:-120}"
DB_PASS="${DB_PASS:-$(kubectl -n "$NAMESPACE" get secret ${CLUSTER}-app -o jsonpath='{.data.password}' | base64 --decode)}"
SKIP_WRITE=false
SKIP_KILL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)    CLUSTER="$2";    shift 2 ;;
    --namespace)  NAMESPACE="$2";  shift 2 ;;
    --skip-write) SKIP_WRITE=true; shift   ;;
    --skip-kill)  SKIP_KILL=true;  shift   ;;
    *) echo "Unknown option: $1"; exit 1   ;;
  esac
done

RUN_ID="chaos-$(date +%s | tail -c 5)"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

pass()  { echo -e "  ${GREEN}✓${RESET}  $*"; }
fail()  { echo -e "  ${RED}✗${RESET}  $*"; }
info()  { echo -e "  ${CYAN}→${RESET}  $*"; }
warn()  { echo -e "  ${YELLOW}!${RESET}  $*"; }
title() { echo -e "\n${BOLD}$*${RESET}"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
kc() { kubectl -n "$NAMESPACE" "$@"; }

psql_exec() {
  # $1 = pod name, rest = psql args
  local pod="$1"; shift
  kc exec "$pod" -- env PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -q -t "$@"
}

get_primary() {
  kc get pod \
    -l "cnpg.io/cluster=${CLUSTER},cnpg.io/instanceRole=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

get_replicas() {
  kc get pod \
    -l "cnpg.io/cluster=${CLUSTER},cnpg.io/instanceRole=replica" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
}

wait_for_primary() {
  local deadline=$(( $(date +%s) + FAILOVER_TIMEOUT ))
  until [[ -n "$(get_primary)" ]]; do
    [[ $(date +%s) -gt $deadline ]] && return 1
    sleep 2
  done
}

# ── Pre-flight ─────────────────────────────────────────────────────────────────
title "CNPG Chaos Test — $RUN_ID"
echo -e "  cluster: ${BOLD}${CLUSTER}${RESET}  namespace: ${BOLD}${NAMESPACE}${RESET}"

PRIMARY=$(get_primary)
if [[ -z "$PRIMARY" ]]; then
  fail "No primary pod found for cluster '$CLUSTER'. Is CNPG running?"
  exit 1
fi

REPLICAS=( $(get_replicas) )
info "Primary: $PRIMARY"
info "Replicas: ${REPLICAS[*]:-none}"

# ── Step 1: Ensure table exists ────────────────────────────────────────────────
title "Step 1 — Ensure chaos_test table exists"
psql_exec "$PRIMARY" -c "
  CREATE TABLE IF NOT EXISTS ${TABLE} (
    id      SERIAL PRIMARY KEY,
    run_id  TEXT NOT NULL,
    val     TEXT,
    written_at TIMESTAMPTZ DEFAULT now()
  );" && pass "Table ready" || { fail "Could not create table"; exit 1; }

# ── Step 2: Write test row ─────────────────────────────────────────────────────
if [[ "$SKIP_WRITE" == false ]]; then
  title "Step 2 — Write test row to primary ($PRIMARY)"
  psql_exec "$PRIMARY" -c \
    "INSERT INTO ${TABLE} (run_id, val) VALUES ('${RUN_ID}', 'chaos-ok');" \
    && pass "Row inserted: run_id=$RUN_ID" \
    || { fail "Insert failed"; exit 1; }

  # ── Step 3: Verify replication ───────────────────────────────────────────────
  title "Step 3 — Verify replication to all replicas"
  if [[ ${#REPLICAS[@]} -eq 0 ]]; then
    warn "No replicas found — skipping replication check"
  else
    sleep 1  # brief lag buffer
    for replica in "${REPLICAS[@]}"; do
      COUNT=$(psql_exec "$replica" -c \
        "SELECT COUNT(*) FROM ${TABLE} WHERE run_id='${RUN_ID}';" 2>/dev/null | tr -d ' ')
      if [[ "$COUNT" -ge 1 ]]; then
        pass "Replica $replica has the row ($COUNT row)"
      else
        fail "Replica $replica is missing the row — replication lag or failure"
        REPL_FAIL=true
      fi
    done
    [[ -n "${REPL_FAIL:-}" ]] && exit 1
  fi
else
  warn "Skipping write + replication check (--skip-write)"
fi

# ── Step 4: Kill the primary ───────────────────────────────────────────────────
if [[ "$SKIP_KILL" == false ]]; then
  title "Step 4 — Kill primary pod ($PRIMARY)"
  T_KILL=$(date +%s%3N)
  kc delete pod "$PRIMARY" --grace-period=0 --force \
    && pass "Pod $PRIMARY deleted" \
    || { fail "Could not delete pod"; exit 1; }

  # ── Step 5: Wait for new primary ──────────────────────────────────────────────
  title "Step 5 — Waiting for new primary election (timeout: ${FAILOVER_TIMEOUT}s)"
  info "Polling every 2s…"
  if wait_for_primary; then
    T_ELECTED=$(date +%s%3N)
    FAILOVER_MS=$(( T_ELECTED - T_KILL ))
    NEW_PRIMARY=$(get_primary)
    pass "New primary elected: $NEW_PRIMARY  (failover in ${FAILOVER_MS}ms)"
  else
    fail "Timed out waiting for primary after ${FAILOVER_TIMEOUT}s"
    exit 1
  fi

  # ── Step 6: Data integrity on new primary ─────────────────────────────────────
  title "Step 6 — Data integrity on new primary ($NEW_PRIMARY)"
  if [[ "$SKIP_WRITE" == false ]]; then
    COUNT=$(psql_exec "$NEW_PRIMARY" -c \
      "SELECT COUNT(*) FROM ${TABLE} WHERE run_id='${RUN_ID}';" 2>/dev/null | tr -d ' ')
    if [[ "$COUNT" -ge 1 ]]; then
      pass "Data intact on new primary ($COUNT row for $RUN_ID)"
    else
      fail "Data missing on new primary — possible data loss!"
      exit 1
    fi
  else
    warn "Skipping data check (no write was done)"
  fi

  # ── Step 7: Cluster topology ─────────────────────────────────────────────────
  title "Step 7 — Cluster topology after failover"
  kc get pods -l "cnpg.io/cluster=${CLUSTER}" -o wide
  echo ""

  # ── Summary ──────────────────────────────────────────────────────────────────
  title "Summary"
  pass "Run ID:         $RUN_ID"
  pass "Old primary:    $PRIMARY (deleted)"
  pass "New primary:    $NEW_PRIMARY"
  [[ -n "${FAILOVER_MS:-}" ]] && pass "Failover time:  ${FAILOVER_MS}ms"
  echo ""
  echo -e "${GREEN}${BOLD}All chaos checks PASSED${RESET}"
else
  warn "Skipping kill + failover check (--skip-kill)"
  echo -e "${GREEN}${BOLD}Write + replication checks PASSED${RESET}"
fi