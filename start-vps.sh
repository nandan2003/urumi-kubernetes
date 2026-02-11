#!/usr/bin/env bash
# One-click VPS wrapper: run start.sh with VM settings.
set +e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR" || exit 1

VM_PUBLIC_IP="${VM_PUBLIC_IP:-}"
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
VITE_ALLOWED_HOSTS="${VITE_ALLOWED_HOSTS:-${DASH_HOST},${VM_PUBLIC_IP}.nip.io,${VM_PUBLIC_IP},localhost,127.0.0.1}"
USE_RBAC="${USE_RBAC:-false}"

if [[ -z "$VM_PUBLIC_IP" ]]; then
  echo "ERROR: VM_PUBLIC_IP is required (example: VM_PUBLIC_IP=20.244.48.232)" >&2
  exit 1
fi

export STACK_MODE
export KUBECONFIG_FILE
export KUBE_CONTEXT=""
export API_ADDR
export DASH_ADDR
export VALUES_FILE
export INGRESS_CLASS
export STORAGE_CLASS
export BUILD_WORDPRESS_IMAGE
export BASE_DOMAIN
export VITE_ALLOWED_HOSTS
export USE_RBAC

exec "$ROOT_DIR/start.sh"
