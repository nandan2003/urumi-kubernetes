#!/usr/bin/env bash
# Safely repair a store missing products and stuck in "coming soon" mode.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

STORE_NAME="${1:-}"
if [[ -z "$STORE_NAME" ]]; then
  die "Usage: scripts/repair-store-products.sh <store-name>"
fi

KUBECONFIG_FILE="${KUBECONFIG_FILE:-$ROOT_DIR/.kube/k3d-urumi-local.yaml}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-urumi-local}"
WP_CLI_PHP_ARGS_VALUE="${WP_CLI_PHP_ARGS_VALUE:--d memory_limit=512M}"

slug="$(echo "$STORE_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-+|-+$//g')"
namespace="store-${slug}"
products_script="$ROOT_DIR/charts/ecommerce-store/files/products.sh"

if [[ ! -f "$products_script" ]]; then
  die "products.sh not found at ${products_script}"
fi

pod="$(kctl -n "$namespace" get pods -l app.kubernetes.io/component=wordpress -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$pod" ]]; then
  die "No WordPress pod found in ${namespace}. Is the store ready?"
fi

wp_exec() {
  kctl -n "$namespace" exec "$pod" -- php $WP_CLI_PHP_ARGS_VALUE /usr/local/bin/wp "$@"
}

log "Checking current product count..."
count="$(wp_exec wc product list --format=count --allow-root --user=admin 2>/dev/null || echo "")"
if [[ -z "$count" ]]; then
  die "Failed to read product count. Check WP CLI connectivity."
fi

log "Ensuring WP memory limits are set in wp-config..."
wp_exec config set WP_MEMORY_LIMIT 256M --allow-root >/dev/null 2>&1 || true
wp_exec config set WP_MAX_MEMORY_LIMIT 512M --allow-root >/dev/null 2>&1 || true

log "Ensuring store visibility is live (disabling coming soon if present)..."
coming_keys="$(wp_exec option list --search='woocommerce_coming_soon%' --field=option_name --allow-root 2>/dev/null || true)"
for key in $coming_keys; do
  wp_exec option update "$key" no --allow-root >/dev/null 2>&1 || true
done
vis_keys="$(wp_exec option list --search='woocommerce_store_visibility%' --field=option_name --allow-root 2>/dev/null || true)"
for key in $vis_keys; do
  wp_exec option update "$key" live --allow-root >/dev/null 2>&1 || true
done

if [[ "$count" -gt 0 ]]; then
  log "Products already exist (${count}). Skipping import."
  exit 0
fi

log "Importing sample products..."
kctl -n "$namespace" cp "$products_script" "$pod:/tmp/urumi-products.sh" >/dev/null 2>&1 || die "Failed to copy products.sh to pod"
kctl -n "$namespace" exec "$pod" -- sh -c "chmod +x /tmp/urumi-products.sh && WP_CLI_PHP_ARGS='$WP_CLI_PHP_ARGS_VALUE' /tmp/urumi-products.sh" >/dev/null 2>&1 || die "Product import failed"

log "Verifying product count..."
count_after="$(wp_exec wc product list --format=count --allow-root --user=admin 2>/dev/null || echo "0")"
log "Product count after import: ${count_after}"
