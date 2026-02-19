#!/usr/bin/env bash
# Safe installer for the demo plugin pack.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

STORE_NAME="${1:-}"
if [[ -z "$STORE_NAME" ]]; then
  die "Usage: scripts/install-demo-plugins.sh <store-name>"
fi

KUBECONFIG_FILE="${KUBECONFIG_FILE:-$ROOT_DIR/.kube/k3d-urumi-local.yaml}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-urumi-local}"

slug="$(echo "$STORE_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-+|-+$//g')"
namespace="store-${slug}"
plugins_file="${PLUGINS_FILE:-$ROOT_DIR/scripts/plugins.txt}"
local_plugin_dir="$ROOT_DIR/charts/ecommerce-store/files/urumi-campaign-tools"
local_caps_file="$ROOT_DIR/charts/ecommerce-store/files/urumi-campaign-tools/urumi-capabilities.json"
WP_CLI_PHP_ARGS_VALUE="${WP_CLI_PHP_ARGS_VALUE:--d memory_limit=512M}"

if [[ ! -f "$plugins_file" ]]; then
  die "Plugin list not found at ${plugins_file}"
fi

log "Looking for WordPress pod in ${namespace}..."
pod="$(kctl -n "$namespace" get pods -l app.kubernetes.io/component=wordpress -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$pod" ]]; then
  die "No WordPress pod found in ${namespace}. Is the store ready?"
fi

wp_exec() {
  kctl -n "$namespace" exec "$pod" -- env WP_CLI_PHP_ARGS="$WP_CLI_PHP_ARGS_VALUE" wp "$@"
}

log "Installing demo plugins into ${namespace}/${pod}..."
while IFS= read -r plugin || [[ -n "$plugin" ]]; do
  plugin="$(echo "$plugin" | sed -E 's/#.*$//' | xargs)"
  if [[ -z "$plugin" ]]; then
    continue
  fi
  if [[ "$plugin" == "urumi-campaign-tools" ]]; then
    if [[ -d "$local_plugin_dir" ]]; then
      log "Installing local plugin ${plugin}..."
      kctl -n "$namespace" exec "$pod" -- mkdir -p /var/www/html/wp-content/plugins >/dev/null 2>&1 || true
      kctl -n "$namespace" cp "$local_plugin_dir" "$pod:/var/www/html/wp-content/plugins/" >/dev/null 2>&1 || warn "Failed to copy ${plugin}"
      if [[ -f "$local_caps_file" ]]; then
        kctl -n "$namespace" cp "$local_caps_file" "$pod:/var/www/html/wp-content/plugins/urumi-campaign-tools/urumi-capabilities.json" >/dev/null 2>&1 || warn "Failed to copy capabilities"
      fi
      wp_exec plugin activate urumi-campaign-tools --allow-root >/dev/null 2>&1 || warn "Failed to activate ${plugin}"
    else
      warn "Local plugin directory not found at ${local_plugin_dir}"
    fi
    continue
  fi
  if wp_exec plugin is-installed "$plugin" --allow-root >/dev/null 2>&1; then
    if wp_exec plugin is-active "$plugin" --allow-root >/dev/null 2>&1; then
      log "✓ ${plugin} already installed and active"
      continue
    fi
    log "Activating ${plugin}..."
    wp_exec plugin activate "$plugin" --allow-root >/dev/null 2>&1 || warn "Failed to activate ${plugin}"
    continue
  fi
  log "Installing ${plugin}..."
  wp_exec plugin install "$plugin" --activate --allow-root >/dev/null 2>&1 || warn "Failed to install ${plugin}"
done < "$plugins_file"

log "Installed plugins:"
wp_exec plugin list --allow-root || true
