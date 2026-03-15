#!/usr/bin/env bash
# cnpg-write-failover.sh — Write-during-failover durability test for CloudNativePG
# Runs a continuous insert loop while killing the primary, then checks for data loss.
#
# Usage:
#   ./cnpg-write-failover.sh [options]
#
# Options:
#   --cluster NAME       CNPG cluster name (default: my-pg-cluster)
#   --namespace NS       Kubernetes namespace (default: default)
#   --write-interval MS  Milliseconds between writes (default: 100)
#   --warmup-secs N      Seconds to write before killing primary (default: 3)
#   --cooldown-secs N    Seconds to keep writing after new primary elected (default: 5)

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CLUSTER="${CLUSTER:-my-pg-cluster}"
NAMESPACE="${NAMESPACE:-default}"
DB_NAME="${DB_NAME:-app_db}"
DB_USER="${DB_USER:-app_user}"
TABLE="write_failover_test"
WRITE_INTERVAL_MS="${WRITE_INTERVAL_MS:-100}"
WARMUP_SECS="${WARMUP_SECS:-3}"
COOLDOWN_SECS="${COOLDOWN_SECS:-5}"
FAILOVER_TIMEOUT=120

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)         CLUSTER="$2";          shift 2 ;;
    --namespace)       NAMESPACE="$2";        shift 2 ;;
    --write-interval)  WRITE_INTERVAL_MS="$2"; shift 2 ;;
    --warmup-secs)     WARMUP_SECS="$2";      shift 2 ;;
    --cooldown-secs)   COOLDOWN_SECS="$2";    shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

RUN_ID="wf-$(date +%s | tail -c 5)"
WRITE_INTERVAL_SECS=$(echo "scale=3; $WRITE_INTERVAL_MS / 1000" | bc)

# ── Temp files for IPC between background writer and main process ─────────────
STOP_FILE=$(mktemp)
WRITE_LOG=$(mktemp)
rm "$STOP_FILE"   # writer loops until this file exists

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
  local pod="$1"; shift
  kc exec "$pod" -- env PGPASSWORD="$DB_PASS" \
    psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -q -t "$@"
}

get_primary() {
  kc get pod \
    -l "cnpg.io/cluster=${CLUSTER},cnpg.io/instanceRole=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

wait_for_primary() {
  local deadline=$(( $(date +%s) + FAILOVER_TIMEOUT ))
  until [[ -n "$(get_primary)" ]]; do
    [[ $(date +%s) -gt $deadline ]] && return 1
    sleep 2
  done
}

now_ms() { date +%s%3N; }

# ── Pre-flight ─────────────────────────────────────────────────────────────────
title "CNPG Write-During-Failover Test — $RUN_ID"
echo -e "  cluster:        ${BOLD}${CLUSTER}${RESET}"
echo -e "  write interval: ${BOLD}${WRITE_INTERVAL_MS}ms${RESET}"
echo -e "  warmup:         ${BOLD}${WARMUP_SECS}s${RESET} before kill"
echo -e "  cooldown:       ${BOLD}${COOLDOWN_SECS}s${RESET} after election"

DB_PASS=$(kubectl -n "$NAMESPACE" get secret "${CLUSTER}-app" \
  -o jsonpath='{.data.password}' | base64 --decode)

INITIAL_PRIMARY=$(get_primary)
if [[ -z "$INITIAL_PRIMARY" ]]; then
  fail "No primary pod found for cluster '$CLUSTER'"
  exit 1
fi
info "Primary: $INITIAL_PRIMARY"

# ── Setup table ───────────────────────────────────────────────────────────────
title "Step 1 — Prepare write_failover_test table"
psql_exec "$INITIAL_PRIMARY" -c "
  DROP TABLE IF EXISTS ${TABLE};
  CREATE TABLE ${TABLE} (
    seq        BIGSERIAL PRIMARY KEY,
    run_id     TEXT NOT NULL,
    written_at TIMESTAMPTZ DEFAULT now(),
    write_ms   BIGINT,
    pod        TEXT
  );" && pass "Table created (fresh for this run)" || { fail "Table setup failed"; exit 1; }

# ── Background writer ──────────────────────────────────────────────────────────
title "Step 2 — Start continuous writer (every ${WRITE_INTERVAL_MS}ms)"

writer_loop() {
  local seq=0
  while [[ ! -f "$STOP_FILE" ]]; do
    seq=$(( seq + 1 ))
    local t_start
    t_start=$(now_ms)
    local current_primary
    current_primary=$(kubectl -n "$NAMESPACE" get pod \
      -l "cnpg.io/cluster=${CLUSTER},cnpg.io/instanceRole=primary" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [[ -z "$current_primary" ]]; then
      echo "SKIP $seq $(now_ms) no-primary" >> "$WRITE_LOG"
      sleep "$WRITE_INTERVAL_SECS"
      continue
    fi

    if kubectl -n "$NAMESPACE" exec "$current_primary" -- \
        env PGPASSWORD="$DB_PASS" \
        psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -q -t -c \
        "INSERT INTO ${TABLE} (run_id, write_ms, pod) VALUES ('${RUN_ID}', $(now_ms), '${current_primary}');" \
        >/dev/null 2>&1; then
      echo "OK $seq $(now_ms) $current_primary" >> "$WRITE_LOG"
    else
      echo "ERR $seq $(now_ms) ${current_primary:-unknown}" >> "$WRITE_LOG"
    fi

    sleep "$WRITE_INTERVAL_SECS"
  done
}

writer_loop &
WRITER_PID=$!
info "Writer started (PID $WRITER_PID)"

# ── Warmup ────────────────────────────────────────────────────────────────────
title "Step 3 — Warmup: writing for ${WARMUP_SECS}s before kill"
sleep "$WARMUP_SECS"
WARMUP_COUNT=$(grep -c "^OK" "$WRITE_LOG" 2>/dev/null || echo 0)
info "$WARMUP_COUNT rows written during warmup"

# ── Kill primary ──────────────────────────────────────────────────────────────
title "Step 4 — Kill primary pod ($INITIAL_PRIMARY)"
T_KILL=$(now_ms)
kc delete pod "$INITIAL_PRIMARY" --grace-period=0 --force 2>/dev/null
pass "Pod $INITIAL_PRIMARY deleted at ${T_KILL}ms"
info "Writer continues through the outage window..."

# ── Wait for election ─────────────────────────────────────────────────────────
title "Step 5 — Waiting for new primary election"
if wait_for_primary; then
  T_ELECTED=$(now_ms)
  FAILOVER_MS=$(( T_ELECTED - T_KILL ))
  NEW_PRIMARY=$(get_primary)
  pass "New primary: $NEW_PRIMARY (elected in ${FAILOVER_MS}ms)"
else
  touch "$STOP_FILE"
  wait "$WRITER_PID" 2>/dev/null || true
  fail "Timed out waiting for new primary"
  exit 1
fi

# ── Cooldown ──────────────────────────────────────────────────────────────────
info "Writing for ${COOLDOWN_SECS}s after election to confirm new primary takes writes..."
sleep "$COOLDOWN_SECS"

# ── Stop writer ───────────────────────────────────────────────────────────────
touch "$STOP_FILE"
wait "$WRITER_PID" 2>/dev/null || true
pass "Writer stopped"

# ── Analyse write log ─────────────────────────────────────────────────────────
title "Step 6 — Analyse write log"

TOTAL_ATTEMPTS=$(wc -l < "$WRITE_LOG" | tr -d ' ')
OK_COUNT=$(grep -c "^OK"   "$WRITE_LOG" 2>/dev/null || echo 0)
ERR_COUNT=$(grep -c "^ERR" "$WRITE_LOG" 2>/dev/null || echo 0)
SKIP_COUNT=$(grep -c "^SKIP" "$WRITE_LOG" 2>/dev/null || echo 0)

info "Total write attempts: $TOTAL_ATTEMPTS"
info "  OK:   $OK_COUNT"
info "  ERR:  $ERR_COUNT  (insert failed — expected during outage)"
info "  SKIP: $SKIP_COUNT (no primary visible — expected during election)"

# Find the outage window from the write log
FIRST_ERR_MS=$(grep "^ERR\|^SKIP" "$WRITE_LOG" | head -1 | awk '{print $3}' || true)
LAST_ERR_MS=$(grep  "^ERR\|^SKIP" "$WRITE_LOG" | tail -1 | awk '{print $3}' || true)

if [[ -n "$FIRST_ERR_MS" && -n "$LAST_ERR_MS" ]]; then
  OUTAGE_MS=$(( LAST_ERR_MS - FIRST_ERR_MS ))
  info "Write outage window: ${OUTAGE_MS}ms  (first error → last error)"
fi

# ── Query new primary for committed rows ──────────────────────────────────────
title "Step 7 — Count committed rows on new primary"
sleep 2  # brief lag buffer for any in-flight replication

DB_COUNT=$(psql_exec "$NEW_PRIMARY" -c \
  "SELECT COUNT(*) FROM ${TABLE} WHERE run_id='${RUN_ID}';" | tr -d ' ')

info "Rows committed in DB: $DB_COUNT  (of $OK_COUNT the writer reported OK)"

# Check for sequence gaps
GAP_COUNT=$(psql_exec "$NEW_PRIMARY" -c "
  SELECT COUNT(*) FROM (
    SELECT seq,
           seq - LAG(seq) OVER (ORDER BY seq) AS gap
    FROM ${TABLE}
    WHERE run_id='${RUN_ID}'
  ) g WHERE gap > 1;" | tr -d ' ')

# Show rows written before vs after failover
PRE_KILL=$(psql_exec "$NEW_PRIMARY" -c \
  "SELECT COUNT(*) FROM ${TABLE} WHERE run_id='${RUN_ID}' AND write_ms < ${T_KILL};" | tr -d ' ')
POST_ELECT=$(psql_exec "$NEW_PRIMARY" -c \
  "SELECT COUNT(*) FROM ${TABLE} WHERE run_id='${RUN_ID}' AND write_ms > ${T_ELECTED};" | tr -d ' ')
DURING=$(psql_exec "$NEW_PRIMARY" -c \
  "SELECT COUNT(*) FROM ${TABLE} WHERE run_id='${RUN_ID}' AND write_ms BETWEEN ${T_KILL} AND ${T_ELECTED};" | tr -d ' ')

info "  Pre-kill rows on new primary:   $PRE_KILL"
info "  During-outage rows committed:   $DURING"
info "  Post-election rows committed:   $POST_ELECT"

# ── Summary ───────────────────────────────────────────────────────────────────
title "Summary"
echo ""

if [[ "$GAP_COUNT" -eq 0 ]]; then
  pass "No sequence gaps — no data loss in committed transactions"
else
  warn "$GAP_COUNT sequence gap(s) detected — some committed rows may be missing"
fi

LOST=$(( OK_COUNT - DB_COUNT ))
if [[ "$LOST" -le 0 ]]; then
  pass "Data loss: 0 rows"
else
  warn "Possible data loss: $LOST row(s) reported OK by writer but missing from DB"
  warn "This may indicate writes that were acknowledged before WAL flush — review sync_commit setting"
fi

echo ""
echo -e "  Run ID:             $RUN_ID"
echo -e "  Initial primary:    $INITIAL_PRIMARY"
echo -e "  New primary:        $NEW_PRIMARY"
echo -e "  Failover time:      ${FAILOVER_MS}ms"
[[ -n "${OUTAGE_MS:-}" ]] && \
echo -e "  Write outage:       ${OUTAGE_MS}ms  (ERR/SKIP window in writer)"
echo -e "  Total writes (OK):  $OK_COUNT"
echo -e "  Committed in DB:    $DB_COUNT"
echo -e "  Sequence gaps:      $GAP_COUNT"
echo ""

if [[ "$GAP_COUNT" -eq 0 && "$LOST" -le 0 ]]; then
  echo -e "${GREEN}${BOLD}DURABILITY TEST PASSED — zero data loss on committed writes${RESET}"
else
  echo -e "${YELLOW}${BOLD}DURABILITY TEST COMPLETED WITH WARNINGS — review above${RESET}"
fi

# ── Cleanup temp files ────────────────────────────────────────────────────────
rm -f "$STOP_FILE" "$WRITE_LOG"