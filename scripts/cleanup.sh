#!/usr/bin/env bash
# Cleanup helpers for processes and Kubernetes namespaces.

kill_running_processes() {
  # Kill only processes started by this project.
  if [[ -f "$ROOT_DIR/orchestrator/.orchestrator.pid" ]]; then
    kill "$(cat "$ROOT_DIR/orchestrator/.orchestrator.pid")" >/dev/null 2>&1 || true
    rm -f "$ROOT_DIR/orchestrator/.orchestrator.pid"
  fi
  if [[ -f "$ROOT_DIR/dashboard/.dashboard.pid" ]]; then
    kill "$(cat "$ROOT_DIR/dashboard/.dashboard.pid")" >/dev/null 2>&1 || true
    rm -f "$ROOT_DIR/dashboard/.dashboard.pid"
  fi
  stop_all_port_forwards
}

python_bin() {
  if command -v python3 >/dev/null 2>&1; then
    echo python3
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    echo python
    return 0
  fi
  return 1
}

nuclear_reset() {
  # Full reset: delete cluster, logs, and cached data.
  log "Nuclear reset: deleting cluster, killing processes, wiping local data..."
  kill_running_processes
  rm -f "$ROOT_DIR/orchestrator/data/stores.json"
  rm -f "$ROOT_DIR/orchestrator/orchestrator.log" "$ROOT_DIR/dashboard/dashboard.log"
  rm -f "$ROOT_DIR/charts/ecommerce-store/files/products.sh"
  if command -v k3d >/dev/null 2>&1; then
    k3d cluster delete "$K3D_CLUSTER" >/dev/null 2>&1 || true
  fi
  docker rmi -f urumi-wordpress:latest >/dev/null 2>&1 || true
}

finalize_namespace() {
  # Remove finalizers to unblock terminating namespaces.
  local ns="$1"
  local py
  py="$(python_bin)" || {
    warn "python not found; skipping finalizer cleanup for ${ns}"
    return
  }
  kctl get ns "$ns" -o json 2>/dev/null | "$py" - <<'PY' | kctl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
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
  # Delete namespaces and force-finalize if stuck (parallelized).
  local list="$1"
  if [[ -z "$list" ]]; then
    return
  fi

  # 1. Trigger deletion for all target namespaces
  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    log "Deleting namespace ${ns}..."
    kctl delete ns "$ns" --wait=false >/dev/null 2>&1 || true
  done <<<"$list"

  # 2. Monitor and finalize in parallel background jobs
  local pids=""
  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    (
      for _ in $(seq 1 30); do
        if ! kctl get ns "$ns" >/dev/null 2>&1; then
          return 0
        fi
        phase="$(kctl get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        if [[ "$phase" == "Terminating" ]]; then
          finalize_namespace "$ns"
        fi
        sleep 2
      done
    ) &
    pids="$pids $!"
  done <<<"$list"

  # 3. Wait for all background jobs to finish
  if [[ -n "$pids" ]]; then
    wait $pids
  fi
}

cleanup_failed_stores() {
  # Preserve Ready + recent Provisioning, delete the rest.
  if [[ "$CLEANUP_STORES" == "false" ]]; then
    return
  fi
  log "Cleaning failed/stuck store namespaces..."
  KEEP_FILE="$(mktemp)"
  py="$(python_bin)" || {
    warn "python not found; skipping cleanup of failed stores."
    rm -f "$KEEP_FILE"
    return
  }
  "$py" - <<PY >"$KEEP_FILE"
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
}
