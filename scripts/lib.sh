#!/usr/bin/env bash
# Shared helpers for start.sh (logging, retries, kubectl wrapper).

log() {
  printf "%s\n" "$*"
}

warn() {
  printf "Warning: %s\n" "$*" >&2
}

die() {
  printf "ERROR: %s\n" "$*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "Missing required command: $1"
  fi
}

check_required_tools() {
  local stack_mode="${1:-local}"
  local build_image="${2:-false}"

  require_cmd kubectl
  require_cmd go
  require_cmd npm
  
  if [[ "$build_image" == "true" ]]; then
    require_cmd docker
  fi
  
  if [[ "$stack_mode" == "local" ]]; then
    require_cmd helm
    require_cmd k3d
  else
    require_cmd k3s
  fi
}

retry() {
  local attempts="$1"
  local delay="$2"
  shift 2
  local n=1
  while true; do
    "$@" && return 0
    if [[ "$n" -ge "$attempts" ]]; then
      return 1
    fi
    n=$((n + 1))
    sleep "$delay"
  done
}

kctl() {
  # Prefer the generated kubeconfig/context when available.
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
