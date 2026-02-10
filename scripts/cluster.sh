#!/usr/bin/env bash
# Cluster lifecycle: preflight, create/start, kubeconfig, ingress readiness.

preflight_docker() {
  # Avoid half-starts when Docker is down.
  retry "${PREFLIGHT_RETRIES:-3}" "${PREFLIGHT_SLEEP:-2}" docker info >/dev/null 2>&1
}

preflight_k3d() {
  # Ensure k3d can reach Docker.
  retry "${PREFLIGHT_RETRIES:-3}" "${PREFLIGHT_SLEEP:-2}" k3d cluster list >/dev/null 2>&1
}

write_kubeconfig() {
  # Write kubeconfig to a deterministic path for local tooling.
  mkdir -p "$(dirname "$KUBECONFIG_FILE")"
  if ! k3d kubeconfig get "$K3D_CLUSTER" >"$KUBECONFIG_FILE" 2>/dev/null; then
    warn "Failed to write kubeconfig for cluster ${K3D_CLUSTER}"
    return 1
  fi
  export KUBECONFIG="$KUBECONFIG_FILE"
  export KUBE_CONTEXT="$KUBE_CONTEXT"
  return 0
}

cluster_ready() {
  # k3d "READY/TOTAL" status check.
  status="$(k3d cluster list 2>/dev/null | awk -v c="$K3D_CLUSTER" '$1==c {print $2}')"
  if [[ -z "$status" ]]; then
    return 1
  fi
  ready="${status%%/*}"
  total="${status##*/}"
  [[ "$ready" == "$total" && "$total" != "0" ]]
}

start_cluster_if_needed() {
  # Create or start the cluster, then wait for API readiness.
  if ! k3d cluster list >/dev/null 2>&1; then
    die "k3d cannot talk to Docker. Is the Docker daemon running?"
  fi
  if ! k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$K3D_CLUSTER"; then
    log "k3d cluster '$K3D_CLUSTER' not found. Creating..."
    if ! k3d cluster create "$K3D_CLUSTER" $K3D_CREATE_ARGS >/dev/null 2>&1; then
      die "Failed to create k3d cluster '${K3D_CLUSTER}'."
    fi
  fi
  log "Ensuring k3d cluster is running: ${K3D_CLUSTER}"
  k3d cluster start "$K3D_CLUSTER" >/dev/null 2>&1 || true

  if ! write_kubeconfig >/dev/null 2>&1; then
    die "Unable to load kubeconfig for ${K3D_CLUSTER}."
  fi

  for _ in $(seq 1 "$KUBE_READY_TIMEOUT"); do
    if cluster_ready && kctl get ns >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  die "Kubernetes API not ready after ${KUBE_READY_TIMEOUT}s for cluster ${K3D_CLUSTER}. Try 'k3d cluster start ${K3D_CLUSTER}' or re-run with NUCLEAR_RESET=true."
}

wait_for_ingress() {
  # Wait for ingress controller(s) to be ready to avoid webhook failures.
  if kctl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1; then
    log "Waiting for ingress-nginx controller to be ready..."
    kctl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
      ep="$(kctl -n ingress-nginx get endpoints ingress-nginx-controller-admission -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
      if [[ -n "$ep" ]]; then
        return
      fi
      sleep 2
    done
    warn "ingress-nginx admission webhook not ready; Helm install may fail."
    return
  fi

  if kctl -n kube-system get deploy traefik >/dev/null 2>&1; then
    log "Waiting for traefik controller to be ready..."
    kctl -n kube-system rollout status deploy/traefik --timeout=180s >/dev/null 2>&1 || true
  fi
}

detect_ingress_class() {
  # Select ingress class if not set explicitly.
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
