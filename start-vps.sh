#!/usr/bin/env bash
# One-click VPS runner: orchestrator + dashboard for k3s.
set +e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR" || exit 1

source "$ROOT_DIR/scripts/lib.sh"

VM_PUBLIC_IP="${VM_PUBLIC_IP:-}"
BASE_DOMAIN="${BASE_DOMAIN:-${VM_PUBLIC_IP}.nip.io}"
DASH_PORT="${DASH_PORT:-5173}"
DASH_HOST="${DASH_HOST:-dashboard.${VM_PUBLIC_IP}.nip.io}"
API_ADDR="${API_ADDR:-http://${VM_PUBLIC_IP}:8080}"

KUBECONFIG_FILE="${KUBECONFIG_FILE:-/etc/rancher/k3s/k3s.yaml}"
VALUES_FILE="${VALUES_FILE:-$ROOT_DIR/charts/ecommerce-store/values-prod.yaml}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
STORAGE_CLASS="${STORAGE_CLASS:-local-path}"
BUILD_WORDPRESS_IMAGE="${BUILD_WORDPRESS_IMAGE:-true}"
VITE_ALLOWED_HOSTS="${VITE_ALLOWED_HOSTS:-${DASH_HOST},${VM_PUBLIC_IP}.nip.io,${VM_PUBLIC_IP},localhost,127.0.0.1}"

ORCH_LOG="$ROOT_DIR/orchestrator/orchestrator.log"
DASH_LOG="$ROOT_DIR/dashboard/dashboard.log"

require_cmd kubectl
require_cmd go
require_cmd npm
require_cmd k3s

if [[ -z "$VM_PUBLIC_IP" ]]; then
  die "VM_PUBLIC_IP is required (example: VM_PUBLIC_IP=20.244.48.232)"
fi

if [[ ! -f "$KUBECONFIG_FILE" ]]; then
  die "Kubeconfig not found at $KUBECONFIG_FILE (k3s not installed?)"
fi

if ! kubectl --kubeconfig "$KUBECONFIG_FILE" get nodes >/dev/null 2>&1; then
  die "Kubernetes is not reachable via $KUBECONFIG_FILE"
fi

if [[ "$BUILD_WORDPRESS_IMAGE" == "true" ]]; then
  require_cmd docker
  if ! docker info >/dev/null 2>&1; then
    die "Docker is not healthy. Start Docker and re-run this script."
  fi
fi

cleanup() {
  [[ -n "${DASH_PID:-}" ]] && kill "$DASH_PID" >/dev/null 2>&1 || true
  [[ -n "${ORCH_PID:-}" ]] && kill "$ORCH_PID" >/dev/null 2>&1 || true
}

trap cleanup INT TERM EXIT

if [[ "$BUILD_WORDPRESS_IMAGE" == "true" ]]; then
  log "Building custom WordPress image..."
  if ! docker build -t urumi-wordpress:latest -f "$ROOT_DIR/Dockerfile" "$ROOT_DIR"; then
    die "Docker build failed."
  fi
  log "Importing image into k3s containerd..."
  if ! docker save urumi-wordpress:latest -o /tmp/urumi-wordpress.tar; then
    die "Docker save failed."
  fi
  if ! sudo k3s ctr images import /tmp/urumi-wordpress.tar; then
    rm -f /tmp/urumi-wordpress.tar
    die "k3s image import failed."
  fi
  rm -f /tmp/urumi-wordpress.tar
fi

log "Starting orchestrator..."
cd "$ROOT_DIR/orchestrator" || exit 1
KUBECONFIG="$KUBECONFIG_FILE" \
STORE_BASE_DOMAIN="$BASE_DOMAIN" \
INGRESS_CLASS="$INGRESS_CLASS" \
STORAGE_CLASS="$STORAGE_CLASS" \
VALUES_FILE="$VALUES_FILE" \
go run . >"$ORCH_LOG" 2>&1 &
ORCH_PID=$!
echo "$ORCH_PID" >"$ROOT_DIR/orchestrator/.orchestrator.pid"

log "Starting dashboard..."
cd "$ROOT_DIR/dashboard" || exit 1
if [[ ! -d "$ROOT_DIR/dashboard/node_modules" ]]; then
  VITE_API_BASE="$API_ADDR" npm install
  if [[ "$?" -ne 0 ]]; then
    die "npm install failed. Fix Node/npm and re-run."
  fi
fi
VITE_ALLOWED_HOSTS="$VITE_ALLOWED_HOSTS" \
VITE_API_BASE="$API_ADDR" \
npm run dev -- --host 0.0.0.0 --port "$DASH_PORT" >"$DASH_LOG" 2>&1 &
DASH_PID=$!
echo "$DASH_PID" >"$ROOT_DIR/dashboard/.dashboard.pid"

cat <<INFO

Urumi VPS Stack
==============
Dashboard: http://${DASH_HOST}:${DASH_PORT}
API:       ${API_ADDR}/healthz
Stores:    http://<store-id>.${BASE_DOMAIN}
Admin:     http://<store-id>.${BASE_DOMAIN}/wp-admin

If the dashboard shows API Offline:
- Confirm http://${VM_PUBLIC_IP}:8080/healthz from your PC.
- Ensure Azure NSG allows inbound 8080 and 5173.
INFO

wait
