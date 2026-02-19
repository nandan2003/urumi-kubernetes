#!/usr/bin/env bash
# One-click local stack runner: cluster + images + orchestrator + dashboard.
set +e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# Guard: ensure helper scripts exist (prevents partial copies).
if [[ ! -d "$ROOT_DIR/scripts" ]]; then
  echo "ERROR: scripts/ folder not found. Please run start.sh from the repo root." >&2
  exit 1
fi

# Configuration (env-overridable).
API_ADDR="${API_ADDR:-http://localhost:8080}"
DASH_PORT="${DASH_PORT:-5173}"
DASH_ADDR="${DASH_ADDR:-http://localhost:${DASH_PORT}}"
AI_ENABLE="${AI_ENABLE:-true}"
AI_PORT="${AI_PORT:-8000}"
AI_ADDR="${AI_ADDR:-http://localhost:${AI_PORT}}"
AI_DIR="${AI_DIR:-$ROOT_DIR/ai-orchestrator}"
AI_VENV_PATH="${AI_VENV_PATH:-$AI_DIR/.venv}"
AI_AUTO_INSTALL_DEPS="${AI_AUTO_INSTALL_DEPS:-true}"
AI_WP_CLI_PHP_ARGS="${AI_WP_CLI_PHP_ARGS:--d memory_limit=512M}"
AUTO_INSTALL_PLUGINS="${AUTO_INSTALL_PLUGINS:-true}"
PLUGINS_FILE="${PLUGINS_FILE:-$ROOT_DIR/scripts/plugins.txt}"
PLUGINS="${PLUGINS:-}"
PORT_FWD_PORT="${PORT_FWD_PORT:-9999}"
ADMIN_PORT_BASE="${ADMIN_PORT_BASE:-9999}"
ADMIN_PORT_MAX="${ADMIN_PORT_MAX:-11000}"
CLEANUP_STORES="${CLEANUP_STORES:-true}"
STUCK_MINUTES="${STUCK_MINUTES:-20}"
STORE_ID="${1:-}"
STOP_CLUSTER_ON_EXIT="${STOP_CLUSTER_ON_EXIT:-true}"
DELETE_CLUSTER_ON_EXIT="${DELETE_CLUSTER_ON_EXIT:-false}"
KUBE_READY_TIMEOUT="${KUBE_READY_TIMEOUT:-60}"
NUCLEAR_RESET="${NUCLEAR_RESET:-false}"
USE_RBAC="${USE_RBAC:-auto}"
STACK_MODE="${STACK_MODE:-local}"
BUILD_WORDPRESS_IMAGE="${BUILD_WORDPRESS_IMAGE:-true}"
K3D_CLUSTER="${K3D_CLUSTER:-urumi-local}"
K3D_API_PORT="${K3D_API_PORT:-6443}"
K3D_CREATE_ARGS="${K3D_CREATE_ARGS:---servers 1 --agents 0 --port 80:80@loadbalancer --port 443:443@loadbalancer --port 6443:6443@loadbalancer}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$ROOT_DIR/.kube/k3d-${K3D_CLUSTER}.yaml}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER}}"
ORCH_KUBECONFIG="${ORCH_KUBECONFIG:-$KUBECONFIG_FILE}"
AI_KUBECONFIG="${AI_KUBECONFIG:-$ORCH_KUBECONFIG}"
PF_STATE_FILE="${PF_STATE_FILE:-$ROOT_DIR/.state/admin-port-forwards.txt}"
PREFLIGHT_RETRIES="${PREFLIGHT_RETRIES:-3}"
PREFLIGHT_SLEEP="${PREFLIGHT_SLEEP:-2}"

ORCH_LOG="$ROOT_DIR/orchestrator/orchestrator.log"
DASH_LOG="$ROOT_DIR/dashboard/dashboard.log"
AI_LOG="$ROOT_DIR/ai-orchestrator/ai-orchestrator.log"
SAMPLE_CSV="$ROOT_DIR/charts/ecommerce-store/files/sample-products.csv"
STORES_JSON="$ROOT_DIR/orchestrator/data/stores.json"

if [[ "$K3D_CREATE_ARGS" != *"--api-port"* ]]; then
  K3D_CREATE_ARGS="$K3D_CREATE_ARGS --api-port ${K3D_API_PORT}"
fi

# Shared helpers + phase modules.
source "$ROOT_DIR/scripts/lib.sh"
source "$ROOT_DIR/scripts/cluster.sh"
source "$ROOT_DIR/scripts/images.sh"
source "$ROOT_DIR/scripts/ports.sh"
source "$ROOT_DIR/scripts/cleanup.sh"
source "$ROOT_DIR/scripts/products.sh"
source "$ROOT_DIR/scripts/rbac.sh"
source "$ROOT_DIR/scripts/ai.sh"

if [[ "$AUTO_INSTALL_PLUGINS" == "true" && ! -f "$PLUGINS_FILE" ]]; then
  warn "Plugins file not found at ${PLUGINS_FILE}; disabling auto plugin install."
  AUTO_INSTALL_PLUGINS="false"
fi

start_orchestrator() {
  # Start Go API (logs to orchestrator.log).
  cd "$ROOT_DIR/orchestrator" || return 1
  KUBECONFIG="$ORCH_KUBECONFIG" \
  STORAGE_CLASS="$STORAGE_CLASS" \
  STORE_BASE_DOMAIN="$BASE_DOMAIN" \
  INGRESS_CLASS="$INGRESS_CLASS" \
  VALUES_FILE="$VALUES_FILE" \
  WP_ADMIN_USER="admin" \
  WP_ADMIN_EMAIL="admin@example.com" \
  AUTO_INSTALL_PLUGINS="$AUTO_INSTALL_PLUGINS" \
  PLUGINS_FILE="$PLUGINS_FILE" \
  PLUGINS="$PLUGINS" \
  go run . >"$ORCH_LOG" 2>&1 &
  ORCH_PID=$!
  echo "$ORCH_PID" >"$ROOT_DIR/orchestrator/.orchestrator.pid"
  cd "$ROOT_DIR" || return 1
}

start_dashboard() {
  # Start Vite dev server (logs to dashboard.log).
  cd "$ROOT_DIR/dashboard" || return 1
  local extra_args=()
  if [[ "$STACK_MODE" == "vps" ]]; then
    extra_args=(-- --host 0.0.0.0 --port "$DASH_PORT")
  fi
  local ai_env=()
  if [[ "$AI_ENABLE" == "true" ]]; then
    ai_env=(VITE_AI_URL="$AI_ADDR")
  fi
  if [[ -n "${VITE_ALLOWED_HOSTS:-}" ]]; then
    env VITE_ALLOWED_HOSTS="$VITE_ALLOWED_HOSTS" VITE_API_BASE="$API_ADDR" "${ai_env[@]}" npm run dev "${extra_args[@]}" >"$DASH_LOG" 2>&1 &
  else
    env VITE_API_BASE="$API_ADDR" "${ai_env[@]}" npm run dev "${extra_args[@]}" >"$DASH_LOG" 2>&1 &
  fi
  DASH_PID=$!
  echo "$DASH_PID" >"$ROOT_DIR/dashboard/.dashboard.pid"
  cd "$ROOT_DIR" || return 1
}

print_summary() {
  # Print endpoints for quick access.
  if [[ "$STACK_MODE" == "vps" ]]; then
    cat <<INFO

Urumi VPS Stack
===============
Dashboard: ${DASH_ADDR}
API:       ${API_ADDR}/healthz
AI:        ${AI_ADDR}
Store:     http://<store-id>.${BASE_DOMAIN}
Admin:     http://<store-id>.${BASE_DOMAIN}/wp-admin
INFO
    return
  fi
  cat <<INFO

Urumi Local Stack
=================
Dashboard: ${DASH_ADDR}
API:       ${API_ADDR}/healthz
AI:        ${AI_ADDR}
Admin:     ports start at http://localhost:${ADMIN_PORT_BASE}/wp-admin (assigned per store)
INFO
}

cleanup() {
  # Clean up processes started by this script.
  [[ -n "${ADMIN_WATCH_PID:-}" ]] && kill "$ADMIN_WATCH_PID" >/dev/null 2>&1 || true
  [[ -n "${DASH_PID:-}" ]] && kill "$DASH_PID" >/dev/null 2>&1 || true
  [[ -n "${ORCH_PID:-}" ]] && kill "$ORCH_PID" >/dev/null 2>&1 || true
  [[ -n "${AI_PID:-}" ]] && kill "$AI_PID" >/dev/null 2>&1 || true
  if [[ "${AI_VENV_ACTIVE:-false}" == "true" ]]; then
    deactivate >/dev/null 2>&1 || true
  fi
  kill_running_processes
  if [[ "$DELETE_CLUSTER_ON_EXIT" == "true" ]]; then
    k3d cluster delete "$K3D_CLUSTER" >/dev/null 2>&1 || true
  elif [[ "$STOP_CLUSTER_ON_EXIT" == "true" ]]; then
    k3d cluster stop "$K3D_CLUSTER" >/dev/null 2>&1 || true
  fi
}

main() {
  # Preflight, cluster boot, image build/import, then services.
  check_required_tools "$STACK_MODE" "$BUILD_WORDPRESS_IMAGE"

  if [[ "$BUILD_WORDPRESS_IMAGE" == "true" ]]; then
    if ! preflight_docker; then
      die "Docker is not healthy. Start Docker (e.g., systemctl start docker) and re-run ./start.sh"
    fi
  fi
  if [[ "$STACK_MODE" == "local" ]]; then
    if ! preflight_k3d; then
      die "k3d is not responding. Ensure Docker is running and re-run ./start.sh"
    fi
    load_port_state
  else
    KUBE_CONTEXT=""
    log "Using k3s cluster via ${KUBECONFIG_FILE}"
  fi

  if [[ "$NUCLEAR_RESET" == "true" ]]; then
    nuclear_reset
  fi

  if [[ "$STACK_MODE" == "local" ]]; then
    start_cluster_if_needed
  else
    if [[ ! -f "$KUBECONFIG_FILE" ]]; then
      die "Kubeconfig not found at ${KUBECONFIG_FILE}. Set KUBECONFIG_FILE for VPS."
    fi
    if ! kctl get ns >/dev/null 2>&1; then
      die "Kubernetes is not reachable via ${KUBECONFIG_FILE}."
    fi
  fi
  wait_for_ingress

  ensure_sample_csv
  generate_products_script

  if [[ "$BUILD_WORDPRESS_IMAGE" == "true" ]]; then
    build_wordpress_image
    if [[ "$STACK_MODE" == "local" ]]; then
      import_k3d_image
    else
      import_k3s_image
    fi
  fi

  kill_running_processes
  cleanup_failed_stores

  if [[ -z "${BASE_DOMAIN:-}" ]]; then
    if [[ "$STACK_MODE" == "vps" ]]; then
      die "BASE_DOMAIN is required for VPS (example: BASE_DOMAIN=20.244.48.232.nip.io)."
    fi
    INGRESS_IP="$(kctl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -z "$INGRESS_IP" ]]; then
      BASE_DOMAIN="127.0.0.1.nip.io"
    else
      BASE_DOMAIN="${INGRESS_IP}.nip.io"
    fi
  fi

  STORAGE_CLASS="${STORAGE_CLASS:-local-path}"
  VALUES_FILE="${VALUES_FILE:-$ROOT_DIR/charts/ecommerce-store/values-local.yaml}"
  detect_ingress_class
  setup_orchestrator_rbac

  trap cleanup INT TERM EXIT

  start_orchestrator
  start_ai_orchestrator
  start_dashboard

  if [[ "$STACK_MODE" == "local" ]]; then
    watch_admin_ports >/dev/null 2>&1 &
    ADMIN_WATCH_PID=$!
  fi

  print_summary
  wait
}

main "$@"
