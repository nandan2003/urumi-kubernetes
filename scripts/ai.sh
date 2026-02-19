#!/usr/bin/env bash
# AI Orchestrator lifecycle management.

start_ai_orchestrator() {
  if [[ "$AI_ENABLE" != "true" ]]; then
    return
  fi
  if [[ ! -d "$AI_DIR" ]]; then
    warn "AI orchestrator folder not found at ${AI_DIR}; skipping."
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found; skipping AI orchestrator."
    return
  fi

  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":${AI_PORT}$"; then
    warn "AI port ${AI_PORT} is already in use; skipping AI orchestrator start."
    return
  fi

  # Create venv if missing.
  if [[ ! -d "$AI_VENV_PATH" ]]; then
    log "Creating AI venv at ${AI_VENV_PATH}..."
    python3 -m venv "$AI_VENV_PATH" >/dev/null 2>&1 || {
      warn "Failed to create venv; skipping AI orchestrator."
      return
    }
  fi

  # Activate venv in current shell (so we can deactivate on exit).
  # shellcheck disable=SC1090
  source "$AI_VENV_PATH/bin/activate"
  AI_VENV_ACTIVE="true"

  if [[ "$AI_AUTO_INSTALL_DEPS" == "true" ]]; then
    if [[ -f "$AI_DIR/requirements.txt" ]]; then
      if [[ ! -f "$AI_VENV_PATH/.deps_installed" || "$AI_DIR/requirements.txt" -nt "$AI_VENV_PATH/.deps_installed" ]]; then
        log "Installing AI dependencies..."
        if pip install -r "$AI_DIR/requirements.txt" >/dev/null 2>&1; then
          touch "$AI_VENV_PATH/.deps_installed"
        else
          warn "AI dependency install failed; skipping AI orchestrator."
          return
        fi
      fi
    fi
  fi

  if ! command -v uvicorn >/dev/null 2>&1; then
    warn "uvicorn not available in AI venv; skipping AI orchestrator."
    return
  fi

  # Load .env if present
  if [[ -f "$AI_DIR/.env" ]]; then
    # shellcheck disable=SC1090
    set -o allexport
    source "$AI_DIR/.env"
    set +o allexport
  fi

  if [[ -z "${AZURE_OPENAI_ENDPOINT:-}" || -z "${AZURE_OPENAI_API_KEY:-}" || -z "${AZURE_OPENAI_DEPLOYMENT:-}" ]]; then
    warn "Azure OpenAI env vars are missing; AI orchestrator may fail at runtime."
  fi

  # Validate AI kubeconfig; fallback to admin kubeconfig if SA token is stale.
  if [[ -n "$AI_KUBECONFIG" && -f "$AI_KUBECONFIG" ]]; then
    if ! kubectl --kubeconfig "$AI_KUBECONFIG" auth can-i get pods -n urumi-system >/dev/null 2>&1; then
      warn "AI kubeconfig is not authorized; falling back to admin kubeconfig."
      AI_KUBECONFIG="$KUBECONFIG_FILE"
    fi
  fi

  log "Starting AI orchestrator..."
  cd "$AI_DIR" || return 1
  local ai_kube_context=""
  if [[ -n "$ORCH_KUBECONFIG" && -f "$ORCH_KUBECONFIG" ]]; then
    local contexts
    contexts="$(kubectl --kubeconfig "$ORCH_KUBECONFIG" config get-contexts -o name 2>/dev/null | awk 'NF')"
    if [[ -n "$KUBE_CONTEXT" ]] && echo "$contexts" | grep -qx "$KUBE_CONTEXT"; then
      ai_kube_context="$KUBE_CONTEXT"
    elif [[ "$(echo "$contexts" | wc -l | tr -d ' ')" == "1" ]]; then
      ai_kube_context="$(echo "$contexts" | head -n 1)"
    fi
  fi

  export KUBECONFIG="$AI_KUBECONFIG"
  export ORCH_API_BASE="$API_ADDR"
  export WP_CLI_PHP_ARGS="$AI_WP_CLI_PHP_ARGS"
  if [[ -n "$ai_kube_context" ]]; then
    export KUBECTL_CONTEXT="$ai_kube_context"
  fi

  uvicorn main:APP --host 0.0.0.0 --port "$AI_PORT" >"$AI_LOG" 2>&1 &
  AI_PID=$!
  cd "$ROOT_DIR" || return 1
}
