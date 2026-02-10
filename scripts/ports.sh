#!/usr/bin/env bash
# Admin port-forward management with PID tracking.

declare -Ag PF_PIDS=()  # store-id -> PID
declare -Ag PF_PORTS=() # store-id -> local port

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

is_port_forward_pid() {
  local pid="$1"
  local id="$2"
  if [[ -z "$pid" ]]; then
    return 1
  fi
  local args
  args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  [[ "$args" == *"kubectl port-forward"* && "$args" == *"urumi-${id}-ecommerce-store-wordpress"* ]]
}

load_port_state() {
  # Restore port-forward state across restarts.
  PF_PIDS=()
  PF_PORTS=()
  [[ -f "$PF_STATE_FILE" ]] || return 0
  while IFS=$'\t' read -r id port pid; do
    [[ -z "$id" ]] && continue
    if is_port_forward_pid "$pid" "$id"; then
      PF_PIDS["$id"]="$pid"
      PF_PORTS["$id"]="$port"
    fi
  done <"$PF_STATE_FILE"
  save_port_state
}

save_port_state() {
  # Persist current port-forward state for safe cleanup.
  mkdir -p "$(dirname "$PF_STATE_FILE")"
  : >"$PF_STATE_FILE"
  local id
  for id in "${!PF_PIDS[@]}"; do
    printf "%s\t%s\t%s\n" "$id" "${PF_PORTS[$id]}" "${PF_PIDS[$id]}" >>"$PF_STATE_FILE"
  done
}

start_admin_port_forward() {
  # Ensure a port-forward for a given store if service exists.
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
  if [[ -n "$pid" ]] && is_port_forward_pid "$pid" "$id"; then
    return
  fi

  kctl -n "$ns" port-forward "svc/$svc" "${port}:80" >/dev/null 2>&1 &
  PF_PIDS["$id"]=$!
  save_port_state
  log "Admin port ready for $id -> http://localhost:${port}/wp-admin"
}

reconcile_admin_port_forwards() {
  # Keep port-forwards in sync with active store namespaces.
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
  save_port_state
}

watch_admin_ports() {
  # Polling loop for local dev (safe and simple).
  while true; do
    reconcile_admin_port_forwards
    sleep 5
  done
}

stop_all_port_forwards() {
  # Stop only port-forwards started by this stack.
  load_port_state
  local id
  for id in "${!PF_PIDS[@]}"; do
    if is_port_forward_pid "${PF_PIDS[$id]}" "$id"; then
      kill "${PF_PIDS[$id]}" >/dev/null 2>&1 || true
    fi
  done
  PF_PIDS=()
  PF_PORTS=()
  save_port_state
}
