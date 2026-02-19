#!/usr/bin/env bash
# RBAC helper: build a ServiceAccount kubeconfig for the orchestrator.

setup_orchestrator_rbac() {
  # Best-effort: fall back to admin kubeconfig if anything fails.
  if [[ "$USE_RBAC" == "false" ]]; then
    ORCH_KUBECONFIG="$KUBECONFIG_FILE"
    return
  fi

  local rbac_file="$ROOT_DIR/orchestrator/orchestrator-rbac.yaml"
  if [[ ! -f "$rbac_file" ]]; then
    warn "RBAC file not found at ${rbac_file}. Falling back to admin kubeconfig."
    ORCH_KUBECONFIG="$KUBECONFIG_FILE"
    return
  fi

  kctl apply -f "$rbac_file" >/dev/null 2>&1 || true

  local token
  token="$(kctl -n urumi-system create token orchestrator 2>/dev/null)"
  if [[ -z "$token" ]]; then
    warn "Failed to create ServiceAccount token; using admin kubeconfig."
    ORCH_KUBECONFIG="$KUBECONFIG_FILE"
    return
  fi

  local server
  local ca_data
  local ca_path
  server="$(kubectl --kubeconfig "$KUBECONFIG_FILE" config view --raw -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
  ca_data="$(kubectl --kubeconfig "$KUBECONFIG_FILE" config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null)"
  if [[ -z "$ca_data" ]]; then
    ca_path="$(kubectl --kubeconfig "$KUBECONFIG_FILE" config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority}' 2>/dev/null)"
    if [[ -n "$ca_path" && -f "$ca_path" ]]; then
      ca_data="$(base64 -w 0 "$ca_path" 2>/dev/null || base64 "$ca_path" | tr -d '\n')"
    fi
  fi

  if [[ -z "$server" || -z "$ca_data" ]]; then
    warn "Failed to build ServiceAccount kubeconfig; using admin kubeconfig."
    ORCH_KUBECONFIG="$KUBECONFIG_FILE"
    return
  fi

  ORCH_KUBECONFIG="$ROOT_DIR/.kube/orchestrator-sa.yaml"
  mkdir -p "$(dirname "$ORCH_KUBECONFIG")"
  cat >"$ORCH_KUBECONFIG" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${K3D_CLUSTER}
  cluster:
    server: ${server}
    certificate-authority-data: ${ca_data}
users:
- name: orchestrator
  user:
    token: ${token}
contexts:
- name: orchestrator
  context:
    cluster: ${K3D_CLUSTER}
    user: orchestrator
    namespace: urumi-system
current-context: orchestrator
EOF
}
