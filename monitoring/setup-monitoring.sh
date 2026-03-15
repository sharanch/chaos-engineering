#!/usr/bin/env bash
# monitoring/setup-monitoring.sh
# Installs kube-prometheus-stack and wires it up to CNPG metrics
# Usage: ./monitoring/setup-monitoring.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

pass()  { echo -e "  ${GREEN}✓${RESET}  $*"; }
fail()  { echo -e "  ${RED}✗${RESET}  $*"; }
info()  { echo -e "  ${CYAN}→${RESET}  $*"; }
warn()  { echo -e "  ${YELLOW}!${RESET}  $*"; }
title() { echo -e "\n${BOLD}$*${RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="$SCRIPT_DIR/kube-prometheus-stack-values.yaml"

# ── Step 1: Helm ───────────────────────────────────────────────────────────────
title "Step 1 — Check Helm"
if ! command -v helm &>/dev/null; then
  fail "Helm not found. Install it:"
  echo "       curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  exit 1
fi
pass "Helm $(helm version --short) found"

# ── Step 2: Add Helm repo ──────────────────────────────────────────────────────
title "Step 2 — Add prometheus-community Helm repo"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update
pass "Repo ready"

# ── Step 3: Install kube-prometheus-stack ─────────────────────────────────────
title "Step 3 — Install kube-prometheus-stack"
if helm status prom-stack -n monitoring &>/dev/null; then
  warn "prom-stack already installed — upgrading instead"
  helm upgrade prom-stack prometheus-community/kube-prometheus-stack \
    -n monitoring \
    -f "$VALUES_FILE" \
    --wait --timeout 5m
else
  helm install prom-stack prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    -f "$VALUES_FILE" \
    --wait --timeout 5m
fi
pass "kube-prometheus-stack deployed"

# ── Step 4: Verify pods ────────────────────────────────────────────────────────
title "Step 4 — Verify monitoring pods"
kubectl get pods -n monitoring
echo ""

# ── Step 5: Check CNPG PodMonitor is visible to Prometheus ────────────────────
title "Step 5 — Verify CNPG PodMonitor"
PM=$(kubectl get podmonitor -n default --no-headers 2>/dev/null | grep -c "my-pg-cluster" || true)
if [[ "$PM" -gt 0 ]]; then
  pass "CNPG PodMonitor found in default namespace"
else
  warn "No PodMonitor found for my-pg-cluster — check your CNPG cluster has monitoring.enablePodMonitor: true"
fi

# ── Step 6: Port-forward instructions ─────────────────────────────────────────
title "Step 6 — Access Grafana"
GRAFANA_POD=$(kubectl get pod -n monitoring -l "app.kubernetes.io/name=grafana" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -n "$GRAFANA_POD" ]]; then
  pass "Grafana pod: $GRAFANA_POD"
  echo ""
  echo -e "  Run this to open Grafana on http://localhost:3000 :"
  echo ""
  echo -e "  ${BOLD}kubectl port-forward -n monitoring svc/prom-stack-grafana 3000:80${RESET}"
  echo ""
  echo -e "  Login: ${BOLD}admin / admin${RESET}"
  echo -e "  Dashboard: Dashboards → CloudNativePG → CNPG Overview"
else
  warn "Grafana pod not found yet — wait a moment and check: kubectl get pods -n monitoring"
fi

# ── Step 7: Port-forward for Prometheus (optional) ────────────────────────────
echo ""
echo -e "  To also access Prometheus UI on http://localhost:9090 :"
echo ""
echo -e "  ${BOLD}kubectl port-forward -n monitoring svc/prom-stack-kube-prometheus-prometheus 9090:9090${RESET}"
echo ""

# ── Step 8: Verify CNPG metrics are being scraped ─────────────────────────────
title "Step 7 — Verify CNPG metrics (run after port-forward is up)"
echo ""
echo "  Once Prometheus is port-forwarded, check these metrics exist:"
echo ""
echo '  curl -s "http://localhost:9090/api/v1/query?query=cnpg_pg_replication_lag" | jq .data.result'
echo '  curl -s "http://localhost:9090/api/v1/query?query=cnpg_backends_total" | jq .data.result'
echo '  curl -s "http://localhost:9090/api/v1/query?query=cnpg_collector_up" | jq .data.result'
echo ""
pass "Setup complete"