#!/usr/bin/env bash
set +e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

API_ADDR="${API_ADDR:-http://localhost:8080}"
DASH_ADDR="${DASH_ADDR:-http://localhost:5173}"
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
K3D_CLUSTER="${K3D_CLUSTER:-urumi-local}"
K3D_API_PORT="${K3D_API_PORT:-6443}"
K3D_CREATE_ARGS="${K3D_CREATE_ARGS:---servers 1 --agents 0 --port 80:80@loadbalancer --port 443:443@loadbalancer --port 6443:6443@loadbalancer}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$ROOT_DIR/.kube/k3d-${K3D_CLUSTER}.yaml}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER}}"

ORCH_LOG="$ROOT_DIR/orchestrator/orchestrator.log"
DASH_LOG="$ROOT_DIR/dashboard/dashboard.log"
SAMPLE_CSV="$ROOT_DIR/charts/ecommerce-store/files/sample-products.csv"
STORES_JSON="$ROOT_DIR/orchestrator/data/stores.json"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd kubectl
require_cmd helm
require_cmd go
require_cmd npm
require_cmd docker

if [[ "$K3D_CREATE_ARGS" != *"--api-port"* ]]; then
  K3D_CREATE_ARGS="$K3D_CREATE_ARGS --api-port ${K3D_API_PORT}"
fi

kctl() {
  if [[ -n "${KUBECONFIG_FILE:-}" && -f "$KUBECONFIG_FILE" ]]; then
    if [[ -n "${KUBE_CONTEXT:-}" ]]; then
      kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$KUBE_CONTEXT" "$@"
    else
      kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"
    fi
  else
    kubectl "$@"
  fi
}

declare -A PF_PIDS
declare -A PF_PORTS

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    if command -v rg >/dev/null 2>&1; then
      ss -lnt | awk '{print $4}' | rg -q ":${port}$"
    else
      ss -lnt | awk '{print $4}' | grep -q ":${port}$"
    fi
    return $?
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  return 1
}

port_taken() {
  local port="$1"
  local p
  for p in "${PF_PORTS[@]}"; do
    if [[ "$p" == "$port" ]]; then
      return 0
    fi
  done
  return 1
}

next_available_port() {
  local port="$ADMIN_PORT_BASE"
  while [[ "$port" -le "$ADMIN_PORT_MAX" ]]; do
    if ! port_in_use "$port" && ! port_taken "$port"; then
      echo "$port"
      return 0
    fi
    port=$((port + 1))
  done
  return 1
}

start_admin_port_forward() {
  local id="$1"
  local ns="store-$id"
  local svc="urumi-$id-ecommerce-store-wordpress"

  if ! kctl -n "$ns" get svc "$svc" >/dev/null 2>&1; then
    return
  fi

  local port="${PF_PORTS[$id]:-}"
  if [[ -z "$port" ]]; then
    port="$(next_available_port)" || return
    PF_PORTS["$id"]="$port"
  fi

  local pid="${PF_PIDS[$id]:-}"
  if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
    return
  fi

  kctl -n "$ns" port-forward "svc/$svc" "${port}:80" >/dev/null 2>&1 &
  PF_PIDS["$id"]=$!
  echo "Admin port ready for $id -> http://localhost:${port}/wp-admin"
}

reconcile_admin_port_forwards() {
  local ids
  ids="$(kctl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk '/^store-/{print substr($0,7)}' | sort)"
  declare -A active=()
  local id
  for id in $ids; do
    active["$id"]=1
    start_admin_port_forward "$id"
  done

  for id in "${!PF_PIDS[@]}"; do
    if [[ -z "${active[$id]:-}" ]]; then
      kill "${PF_PIDS[$id]}" >/dev/null 2>&1 || true
      unset "PF_PIDS[$id]"
      unset "PF_PORTS[$id]"
    fi
  done
}

watch_admin_ports() {
  while true; do
    reconcile_admin_port_forwards
    sleep 5
  done
}

kill_running_processes() {
  if [[ -f "$ROOT_DIR/orchestrator/.orchestrator.pid" ]]; then
    kill "$(cat "$ROOT_DIR/orchestrator/.orchestrator.pid")" >/dev/null 2>&1 || true
    rm -f "$ROOT_DIR/orchestrator/.orchestrator.pid"
  fi
  if [[ -f "$ROOT_DIR/dashboard/.dashboard.pid" ]]; then
    kill "$(cat "$ROOT_DIR/dashboard/.dashboard.pid")" >/dev/null 2>&1 || true
    rm -f "$ROOT_DIR/dashboard/.dashboard.pid"
  fi
  pkill -f "kubectl port-forward" >/dev/null 2>&1 || true
}

write_kubeconfig() {
  if ! command -v k3d >/dev/null 2>&1; then
    return 1
  fi
  mkdir -p "$(dirname "$KUBECONFIG_FILE")"
  if ! k3d kubeconfig get "$K3D_CLUSTER" >"$KUBECONFIG_FILE" 2>/dev/null; then
    echo "Failed to write kubeconfig for cluster ${K3D_CLUSTER}" >&2
    return 1
  fi
  export KUBECONFIG="$KUBECONFIG_FILE"
  export KUBE_CONTEXT="$KUBE_CONTEXT"
  return 0
}

cluster_ready() {
  if ! command -v k3d >/dev/null 2>&1; then
    return 1
  fi
  status="$(k3d cluster list 2>/dev/null | awk -v c="$K3D_CLUSTER" '$1==c {print $2}')"
  if [[ -z "$status" ]]; then
    return 1
  fi
  ready="${status%%/*}"
  total="${status##*/}"
  [[ "$ready" == "$total" && "$total" != "0" ]]
}

nuclear_reset() {
  echo "Nuclear reset: deleting cluster, killing processes, wiping local data..."
  kill_running_processes
  rm -f "$ROOT_DIR/orchestrator/data/stores.json"
  rm -f "$ROOT_DIR/orchestrator/orchestrator.log" "$ROOT_DIR/dashboard/dashboard.log"
  rm -f "$ROOT_DIR/charts/ecommerce-store/files/products.sh"
  if command -v k3d >/dev/null 2>&1; then
    k3d cluster delete "$K3D_CLUSTER" >/dev/null 2>&1 || true
  fi
  docker rmi -f urumi-wordpress:latest >/dev/null 2>&1 || true
}

start_cluster_if_needed() {
  if ! command -v k3d >/dev/null 2>&1; then
    return
  fi
  if ! k3d cluster list >/dev/null 2>&1; then
    echo "k3d cannot talk to Docker. Is the Docker daemon running?" >&2
    exit 1
  fi
  if ! k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$K3D_CLUSTER"; then
    echo "k3d cluster '$K3D_CLUSTER' not found. Creating..."
    if ! k3d cluster create "$K3D_CLUSTER" $K3D_CREATE_ARGS >/dev/null 2>&1; then
      echo "Failed to create k3d cluster '${K3D_CLUSTER}'." >&2
      exit 1
    fi
  fi
  echo "Ensuring k3d cluster is running: ${K3D_CLUSTER}"
  k3d cluster start "$K3D_CLUSTER" >/dev/null 2>&1 || true

  if ! write_kubeconfig >/dev/null 2>&1; then
    echo "ERROR: Unable to load kubeconfig for ${K3D_CLUSTER}." >&2
    exit 1
  fi

  for _ in $(seq 1 "$KUBE_READY_TIMEOUT"); do
    if cluster_ready && kctl get ns >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  echo "ERROR: Kubernetes API not ready after ${KUBE_READY_TIMEOUT}s for cluster ${K3D_CLUSTER}." >&2
  echo "Hint: run 'k3d cluster start ${K3D_CLUSTER}' or 'NUCLEAR_RESET=true ./start.sh'." >&2
  exit 1
}

wait_for_ingress() {
  if kctl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1; then
    echo "Waiting for ingress-nginx controller to be ready..."
    kctl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
      ep="$(kctl -n ingress-nginx get endpoints ingress-nginx-controller-admission -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
      if [[ -n "$ep" ]]; then
        return
      fi
      sleep 2
    done
    echo "Warning: ingress-nginx admission webhook not ready; Helm install may fail." >&2
    return
  fi

  if kctl -n kube-system get deploy traefik >/dev/null 2>&1; then
    echo "Waiting for traefik controller to be ready..."
    kctl -n kube-system rollout status deploy/traefik --timeout=180s >/dev/null 2>&1 || true
  fi
}

detect_ingress_class() {
  if [[ -n "${INGRESS_CLASS:-}" ]]; then
    return
  fi
  if kctl get ingressclass nginx >/dev/null 2>&1; then
    INGRESS_CLASS="nginx"
    return
  fi
  if kctl get ingressclass traefik >/dev/null 2>&1; then
    INGRESS_CLASS="traefik"
    return
  fi
  INGRESS_CLASS="traefik"
}

finalize_namespace() {
  local ns="$1"
  kctl get ns "$ns" -o json 2>/dev/null | python - <<'PY' | kctl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    raise SystemExit(0)
data = json.loads(raw)
data.setdefault("spec", {})["finalizers"] = []
data.setdefault("metadata", {})["finalizers"] = []
print(json.dumps(data))
PY
}

delete_namespaces() {
  local list="$1"
  if [[ -z "$list" ]]; then
    return
  fi
  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    kctl delete ns "$ns" --wait=false >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      if ! kctl get ns "$ns" >/dev/null 2>&1; then
        break
      fi
      phase="$(kctl get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      if [[ "$phase" == "Terminating" ]]; then
        finalize_namespace "$ns"
      fi
      sleep 2
    done
  done <<<"$list"
}

# Generate products.sh from CSV (shell-only installer uses this)
generate_products_script() {
  PRODUCTS_SH="$ROOT_DIR/charts/ecommerce-store/files/products.sh"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found; skipping products.sh generation." >&2
    return
  fi
  python3 - "$SAMPLE_CSV" "$PRODUCTS_SH" <<'PY'
import csv, sys, shlex
csv_path, out_path = sys.argv[1], sys.argv[2]
with open(csv_path, newline='', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    rows = list(reader)
with open(out_path, 'w', encoding='utf-8') as out:
    out.write("#!/bin/sh\n")
    out.write("set +e\n")
    for row in rows:
        name = (row.get("Name") or "").strip()
        if not name:
            continue
        price = (row.get("Regular price") or row.get("Sale price") or "10").strip()
        desc = (row.get("Description") or "").strip()
        short = (row.get("Short description") or "").strip()
        parts = [
            "wp wc product create",
            f"--name={shlex.quote(name)}",
            f"--regular_price={shlex.quote(price)}",
            f"--status=publish",
            f"--user=${{WP_ADMIN_USER}}",
            "--allow-root",
        ]
        if desc:
            parts.append(f"--description={shlex.quote(desc)}")
        if short:
            parts.append(f"--short_description={shlex.quote(short)}")
        out.write(" ".join(parts) + " || true\n")
PY
  chmod +x "$PRODUCTS_SH" >/dev/null 2>&1 || true
}

# Ensure sample CSV exists
if [[ ! -f "$SAMPLE_CSV" ]]; then
  echo "Creating placeholder sample-products.csv..."
  mkdir -p "$(dirname "$SAMPLE_CSV")"
  cat <<'CSV' >"$SAMPLE_CSV"
ID,Type,SKU,Name,Published,"Is featured?","Visibility in catalog","Short description",Description,"Date sale price starts","Date sale price ends","Tax status","Tax class","In stock?",Stock,"Low stock amount","Backorders allowed?","Sold individually?","Weight (kg)","Length (cm)","Width (cm)","Height (cm)","Allow customer reviews?","Purchase note","Sale price","Regular price",Categories,Tags,"Shipping class",Images,"Download limit","Download expiry days",Parent,"Grouped products",Upsells,Cross-sells,"External URL","Button text",Position
1,simple,,Sample Product,1,0,visible,Sample product,Sample product,,,taxable,,1,,,0,0,,,,,1,,,9.99,9.99,Sample,,"",,,,,,,0
CSV
fi

if [[ "$NUCLEAR_RESET" == "true" ]]; then
  nuclear_reset
fi

# Start cluster early (before image import)
start_cluster_if_needed
wait_for_ingress

generate_products_script

# Build and load custom WordPress image
echo "Building custom WordPress image..."
docker build -t urumi-wordpress:latest -f "$ROOT_DIR/Dockerfile" "$ROOT_DIR"

if command -v k3d >/dev/null 2>&1; then
  echo "Importing image into k3d cluster: ${K3D_CLUSTER}"
  IMPORT_OK="false"
  K3D_IMPORT_RETRIES="${K3D_IMPORT_RETRIES:-2}"
  for attempt in $(seq 1 "$K3D_IMPORT_RETRIES"); do
    if k3d image import urumi-wordpress:latest -c "${K3D_CLUSTER}"; then
      IMPORT_OK="true"
      break
    fi
    echo "k3d image import failed (attempt ${attempt}/${K3D_IMPORT_RETRIES}). Retrying..." >&2
    sleep 2
  done
  if [[ "$IMPORT_OK" != "true" ]]; then
    echo "Warning: k3d image import failed. The cluster may try to pull from a registry." >&2
  fi
fi

kill_running_processes

# Cleanup failed/stuck stores (preserve Ready)
if [[ "$CLEANUP_STORES" != "false" ]]; then
  echo "Cleaning failed/stuck store namespaces..."
  KEEP_FILE="$(mktemp)"
  python - <<PY >"$KEEP_FILE"
import json, pathlib, datetime
path = pathlib.Path("$STORES_JSON")
if not path.exists():
    raise SystemExit(0)

data = json.loads(path.read_text())
stores = data.get("stores", {})
order = data.get("order", [])

now = datetime.datetime.now(datetime.timezone.utc)
keep_ids = []
keep_store = {}

for store_id in order:
    store = stores.get(store_id)
    if not store:
        continue
    status = store.get("status")
    updated = store.get("updatedAt")
    keep = False
    if status == "Ready":
        keep = True
    elif status == "Provisioning" and updated:
        try:
            ts = datetime.datetime.fromisoformat(updated.replace("Z", "+00:00"))
            if (now - ts).total_seconds() < int("$STUCK_MINUTES") * 60:
                keep = True
        except Exception:
            keep = False

    if keep:
        keep_ids.append(store_id)
        keep_store[store_id] = store

# rewrite stores.json to only keep Ready + recent Provisioning
new_data = {"stores": keep_store, "order": keep_ids}
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(new_data, indent=2))

for store_id in keep_ids:
    ns = keep_store[store_id].get("namespace")
    if ns:
        print(ns)
PY

  if [[ -s "$KEEP_FILE" ]]; then
    STORE_NAMESPACES="$(kctl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk '/^store-/{print $0}')"
    if [[ -n "$STORE_NAMESPACES" ]]; then
      NAMESPACES_TO_DELETE="$(printf '%s\n' "$STORE_NAMESPACES" | awk 'NR==FNR{keep[$0]=1;next}!keep[$0]' "$KEEP_FILE" -)"
      if [[ -n "$NAMESPACES_TO_DELETE" ]]; then
        delete_namespaces "$NAMESPACES_TO_DELETE"
      fi
    fi
  else
    if [[ -f "$STORES_JSON" ]]; then
      STORE_NAMESPACES="$(kctl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk '/^store-/{print $0}')"
      if [[ -n "$STORE_NAMESPACES" ]]; then
        delete_namespaces "$STORE_NAMESPACES"
      fi
    fi
  fi
  rm -f "$KEEP_FILE"
fi

# Detect ingress IP for nip.io base domain
INGRESS_IP="$(kctl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [[ -z "$INGRESS_IP" ]]; then
  BASE_DOMAIN="127.0.0.1.nip.io"
else
  BASE_DOMAIN="${INGRESS_IP}.nip.io"
fi

STORAGE_CLASS="${STORAGE_CLASS:-local-path}"
VALUES_FILE="${VALUES_FILE:-$ROOT_DIR/charts/ecommerce-store/values-local.yaml}"
detect_ingress_class

cleanup() {
  [[ -n "${PF_PID:-}" ]] && kill "$PF_PID" >/dev/null 2>&1 || true
  [[ -n "${DASH_PID:-}" ]] && kill "$DASH_PID" >/dev/null 2>&1 || true
  [[ -n "${ORCH_PID:-}" ]] && kill "$ORCH_PID" >/dev/null 2>&1 || true
  [[ -n "${ADMIN_WATCH_PID:-}" ]] && kill "$ADMIN_WATCH_PID" >/dev/null 2>&1 || true
  for pid in "${PF_PIDS[@]}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  if [[ "$DELETE_CLUSTER_ON_EXIT" == "true" ]] && command -v k3d >/dev/null 2>&1; then
    k3d cluster delete "$K3D_CLUSTER" >/dev/null 2>&1 || true
  elif [[ "$STOP_CLUSTER_ON_EXIT" == "true" ]] && command -v k3d >/dev/null 2>&1; then
    k3d cluster stop "$K3D_CLUSTER" >/dev/null 2>&1 || true
  fi
}
trap cleanup INT TERM EXIT

# Start orchestrator
cd "$ROOT_DIR/orchestrator"
STORAGE_CLASS="$STORAGE_CLASS" \
STORE_BASE_DOMAIN="$BASE_DOMAIN" \
INGRESS_CLASS="$INGRESS_CLASS" \
VALUES_FILE="$VALUES_FILE" \
WP_ADMIN_USER="admin" \
WP_ADMIN_PASSWORD="password" \
WP_ADMIN_EMAIL="admin@example.com" \
go run . >"$ORCH_LOG" 2>&1 &
ORCH_PID=$!
echo "$ORCH_PID" >"$ROOT_DIR/orchestrator/.orchestrator.pid"

# Start dashboard
cd "$ROOT_DIR/dashboard"
VITE_API_BASE="$API_ADDR" npm run dev >"$DASH_LOG" 2>&1 &
DASH_PID=$!
echo "$DASH_PID" >"$ROOT_DIR/dashboard/.dashboard.pid"

cd "$ROOT_DIR"

watch_admin_ports >/dev/null 2>&1 &
ADMIN_WATCH_PID=$!

cat <<INFO

Urumi Local Stack
=================
Dashboard: ${DASH_ADDR}
API:       ${API_ADDR}/healthz
Admin:     ports start at http://localhost:${ADMIN_PORT_BASE}/wp-admin (assigned per store)
INFO

wait
