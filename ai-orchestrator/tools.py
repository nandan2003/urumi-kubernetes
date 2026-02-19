#!/usr/bin/env python3
"""
Tooling layer for AI Orchestrator.
Core infrastructure for Model Context Protocol (MCP) dynamic binding.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import requests
import time
import shlex
from pathlib import Path
from typing import Any, Dict, Optional

# ---- Config ----
KUBECTL_BIN = os.getenv("KUBECTL_BIN", "kubectl")
KUBECONFIG = os.getenv("KUBECONFIG", "") or os.getenv("ORCH_KUBECONFIG", "")
KUBECTL_CONTEXT = os.getenv("KUBECTL_CONTEXT", "")
ORCH_API_BASE = os.getenv("ORCH_API_BASE", "http://localhost:8080")
WAIT_TIMEOUT_SECONDS = int(os.getenv("WAIT_TIMEOUT_SECONDS", "900"))
WAIT_POLL_SECONDS = int(os.getenv("WAIT_POLL_SECONDS", "5"))
DEFAULT_WP_CLI_USER = os.getenv("WC_CLI_USER") or os.getenv("WP_ADMIN_USER") or "admin"
WP_CLI_BIN = os.getenv("WP_CLI_BIN", "wp")
WP_CLI_PHP_ARGS = os.getenv("WP_CLI_PHP_ARGS", "")

# Cache resolved context ("" means no context).
_RESOLVED_CONTEXT: str | None = None
_POD_CACHE: Dict[str, str] = {}

def get_store_pod_info(store_name: str) -> tuple[str, str]:
    """Returns (namespace, pod_name) for the store, cached to avoid K8s API churn."""
    stores = _fetch_stores()
    match = _match_store_record(store_name, stores or [])
    if not match:
        raise RuntimeError(f"Store {store_name} not found")
    
    namespace = match.get("namespace") or _resolve_store_namespace(store_name, stores)
    pod = _wait_for_wp_pod(namespace)
    return namespace, pod

def run_wp_cli_command(namespace: str, pod: str, wp_args: list[str]) -> str:
    """
    Executes a WP-CLI command safely inside the target pod.
    Automatically adds --allow-root and --user=admin if not present.
    """
    cmd = ["-n", namespace, "exec", pod, "--", *_wp_base_cmd()] + wp_args
    
    # Ensure safety flags
    if "--allow-root" not in wp_args:
        cmd.append("--allow-root")
    
    # Ensure user context for write operations or capability checks
    # We check if it's already there to avoid duplication
    has_user = any(arg.startswith("--user=") for arg in wp_args)
    if not has_user:
        cmd.append("--user=admin")
        
    return _kubectl(cmd)

# Internal Helper Functions

def _kubectl(args: list[str], timeout: int = 30) -> str:
    env = os.environ.copy()
    if KUBECONFIG:
        env["KUBECONFIG"] = KUBECONFIG
    
    cmd = [KUBECTL_BIN]
    resolved_ctx = _resolve_kube_context(env)
    if resolved_ctx:
        cmd.extend(["--context", resolved_ctx])
    cmd += args

    retries = 3
    last_err = ""
    
    for attempt in range(retries):
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=timeout)
            if result.returncode == 0:
                return result.stdout.strip()
            
            stderr = result.stderr.strip()
            # Retry on specific transient errors
            if "connection refused" in stderr or "timeout" in stderr or "EOF" in stderr:
                last_err = stderr
                time.sleep(2 ** attempt) # Exponential backoff: 1s, 2s, 4s
                continue
            
            return f"Error: {stderr}"
            
        except subprocess.TimeoutExpired:
            last_err = f"Command timed out after {timeout}s"
            time.sleep(2 ** attempt)
            continue
        except Exception as e:
            return f"Error: System failure: {str(e)}"
            
    return f"Error: {last_err or 'Command failed after retries'}"

def _resolve_kube_context(env: dict) -> str | None:
    global _RESOLVED_CONTEXT
    if _RESOLVED_CONTEXT is not None:
        return _RESOLVED_CONTEXT or None
    if not KUBECTL_CONTEXT:
        _RESOLVED_CONTEXT = ""
        return None
    contexts = _list_kube_contexts(env)
    if KUBECTL_CONTEXT in contexts:
        _RESOLVED_CONTEXT = KUBECTL_CONTEXT
        return KUBECTL_CONTEXT
    if len(contexts) == 1:
        _RESOLVED_CONTEXT = contexts[0]
        return contexts[0]
    for ctx in contexts:
        if "k3d" in ctx or "urumi" in ctx:
            _RESOLVED_CONTEXT = ctx
            return ctx
    _RESOLVED_CONTEXT = ""
    return None

def _list_kube_contexts(env: dict) -> list[str]:
    cmd = [KUBECTL_BIN, "config", "get-contexts", "-o", "name"]
    result = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]

def _normalize_store_name(text: str) -> str:
    name = (text or "").strip().lower()
    if name.startswith("store "):
        name = name[len("store "):]
    if name.endswith(" store"):
        name = name[: -len(" store")]
    return name.strip()

def _store_namespace(store_name: str) -> str:
    text = _normalize_store_name(store_name)
    text = re.sub(r"[^a-z0-9\s-]", "", text)
    slug = re.sub(r"[\s_-]+", "-", text).strip("-")
    if slug.startswith("store-"):
        return slug
    return f"store-{slug}"

def _fetch_stores() -> Optional[list[dict]]:
    try:
        resp = requests.get(f"{ORCH_API_BASE}/api/stores", timeout=10)
        if resp.status_code != 200:
            return None
        data = resp.json()
        return data if isinstance(data, list) else data.get("stores", [])
    except:
        return None

def _match_store_record(store_name: str, stores: list[dict]) -> Optional[dict]:
    needle = _normalize_store_name(store_name)
    for store in stores:
        if not isinstance(store, dict): continue
        if needle in {str(store.get("name", "")).lower(), str(store.get("id", "")).lower(), str(store.get("namespace", "")).lower()}:
            return store
    return None

def _resolve_store_namespace(store_name: str, stores: Optional[list[dict]] = None) -> str:
    if stores:
        match = _match_store_record(store_name, stores)
        if match: return match.get("namespace") or _store_namespace(store_name)
    return _store_namespace(store_name)

def _wait_for_wp_pod(namespace: str) -> str:
    if namespace in _POD_CACHE:
        return _POD_CACHE[namespace]

    start = time.time()
    while time.time() - start < WAIT_TIMEOUT_SECONDS:
        raw = _kubectl(["-n", namespace, "get", "pods", "-l", "app.kubernetes.io/component=wordpress", "-o", "json"])
        if not raw.startswith("Error:"):
            try:
                data = json.loads(raw)
                for pod in data.get("items", []):
                    if pod.get("status", {}).get("phase") == "Running":
                        name = pod.get("metadata", {}).get("name", "")
                        if name:
                            _POD_CACHE[namespace] = name
                            return name
            except: pass
        time.sleep(WAIT_POLL_SECONDS)
    raise RuntimeError(f"Timeout waiting for pod in {namespace}")

def _wp_base_cmd() -> list[str]:
    if WP_CLI_PHP_ARGS:
        return ["php", *shlex.split(WP_CLI_PHP_ARGS), "/usr/local/bin/wp"]
    return [WP_CLI_BIN]

# Placeholder for compatibility if needed
WC_ALLOWLIST = {}
