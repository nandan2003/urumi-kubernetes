#!/usr/bin/env bash
# One-click VPS runner: orchestrator + dashboard (assumes k3s already running).
set +e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR" || exit 1

source "$ROOT_DIR/scripts/lib.sh"

VM_PUBLIC_IP="${VM_PUBLIC_IP:-20.244.48.232}"
STORE_BASE_DOMAIN="${STORE_BASE_DOMAIN:-${VM_PUBLIC_IP}.nip.io}"
API_ADDR="${API_ADDR:-http://${VM_PUBLIC_IP}:8080}"
DASH_PORT="${DASH_PORT:-5173}"
DASH_ADDR="${DASH_ADDR:-http://dashboard.${VM_PUBLIC_IP}.nip.io:${DASH_PORT}}"

KUBECONFIG_FILE="${KUBECONFIG_FILE:-/etc/rancher/k3s/k3s.yaml}"
VALUES_FILE="${VALUES_FILE:-$ROOT_DIR/charts/ecommerce-store/values-prod.yaml}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
STORAGE_CLASS="${STORAGE_CLASS:-local-path}"

ORCH_LOG="$ROOT_DIR/orchestrator/orchestrator.log"
DASH_LOG="$ROOT_DIR/dashboard/dashboard.log"

require_cmd kubectl
require_cmd go
require_cmd npm

if [[ -z "$VM_PUBLIC_IP" ]]; then
  die "VM_PUBLIC_IP is required (example: VM_PUBLIC_IP=20.244.48.232)"
fi

if [[ ! -f "$KUBECONFIG_FILE" ]]; then
  die "Kubeconfig not found at $KUBECONFIG_FILE (k3s not installed?)"
fi

if ! kubectl --kubeconfig "$KUBECONFIG_FILE" get nodes >/dev/null 2>&1; then
  die "Kubernetes is not reachable via $KUBECONFIG_FILE"
fi

kill_pid_file() {
  local pid_file="$1"
  local label="$2"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file")"
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      local cmd
      cmd="$(ps -p "$pid" -o args= 2>/dev/null || true)"
      if [[ "$cmd" == *"$label"* ]]; then
        kill "$pid" >/dev/null 2>&1 || true
      else
        warn "PID $pid from $pid_file is not a $label process; leaving it running"
      fi
    fi
    rm -f "$pid_file"
  fi
}

cleanup() {
  [[ -n "${DASH_PID:-}" ]] && kill "$DASH_PID" >/dev/null 2>&1 || true
  [[ -n "${ORCH_PID:-}" ]] && kill "$ORCH_PID" >/dev/null 2>&1 || true
}

trap cleanup INT TERM EXIT

kill_pid_file "$ROOT_DIR/orchestrator/.orchestrator.pid" "orchestrator"
kill_pid_file "$ROOT_DIR/dashboard/.dashboard.pid" "vite"

log "Starting orchestrator..."
cd "$ROOT_DIR/orchestrator" || exit 1
KUBECONFIG="$KUBECONFIG_FILE" \
STORE_BASE_DOMAIN="$STORE_BASE_DOMAIN" \
INGRESS_CLASS="$INGRESS_CLASS" \
STORAGE_CLASS="$STORAGE_CLASS" \
VALUES_FILE="$VALUES_FILE" \
go run . >"$ORCH_LOG" 2>&1 &
ORCH_PID=$!
echo "$ORCH_PID" >"$ROOT_DIR/orchestrator/.orchestrator.pid"

log "Starting dashboard..."
cd "$ROOT_DIR/dashboard" || exit 1
if [[ ! -d "$ROOT_DIR/dashboard/node_modules" ]]; then
  VITE_API_BASE="$API_ADDR" npm install >/dev/null 2>&1 || true
fi
VITE_API_BASE="$API_ADDR" npm run dev -- --host 0.0.0.0 --port "$DASH_PORT" >"$DASH_LOG" 2>&1 &
DASH_PID=$!
echo "$DASH_PID" >"$ROOT_DIR/dashboard/.dashboard.pid"

cat <<INFO

Urumi VPS Stack
==============
Dashboard: ${DASH_ADDR}
API:       ${API_ADDR}/healthz
Stores:    http://<store-id>.${VM_PUBLIC_IP}.nip.io
Admin:     http://<store-id>.${VM_PUBLIC_IP}.nip.io/wp-admin

If the dashboard shows API Offline:
- Confirm http://${VM_PUBLIC_IP}:8080/healthz from your PC.
- Ensure Azure NSG allows inbound 8080 and 5173.
INFO

wait
