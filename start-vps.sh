#!/usr/bin/env bash
# One-click VPS wrapper: runs start.sh with VPS settings.
set +e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR" || exit 1

VM_PUBLIC_IP="${VM_PUBLIC_IP:-20.244.48.232}"
BASE_DOMAIN="${BASE_DOMAIN:-${VM_PUBLIC_IP}.nip.io}"
DASH_PORT="${DASH_PORT:-5173}"
DASH_HOST="${DASH_HOST:-dashboard.${VM_PUBLIC_IP}.nip.io}"

STACK_MODE="${STACK_MODE:-vps}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-/etc/rancher/k3s/k3s.yaml}"
API_ADDR="${API_ADDR:-http://${VM_PUBLIC_IP}:8080}"
DASH_ADDR="${DASH_ADDR:-http://${DASH_HOST}:${DASH_PORT}}"
VALUES_FILE="${VALUES_FILE:-$ROOT_DIR/charts/ecommerce-store/values-prod.yaml}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
STORAGE_CLASS="${STORAGE_CLASS:-local-path}"
BUILD_WORDPRESS_IMAGE="${BUILD_WORDPRESS_IMAGE:-true}"
VITE_ALLOWED_HOSTS="${VITE_ALLOWED_HOSTS:-${DASH_HOST},${VM_PUBLIC_IP}.nip.io,localhost,127.0.0.1}"

if [[ ! -f "$ROOT_DIR/start.sh" ]]; then
  echo "ERROR: start.sh not found in $ROOT_DIR" >&2
  exit 1
fi

export STACK_MODE
export KUBECONFIG_FILE
export API_ADDR
export DASH_ADDR
export VALUES_FILE
export INGRESS_CLASS
export STORAGE_CLASS
export BUILD_WORDPRESS_IMAGE
export BASE_DOMAIN
export VITE_ALLOWED_HOSTS

exec "$ROOT_DIR/start.sh"
