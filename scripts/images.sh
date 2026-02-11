#!/usr/bin/env bash
# Image build/import for local k3d.

build_wordpress_image() {
  # Build a local WordPress image for faster installs.
  if [[ "${FORCE_REBUILD_WORDPRESS:-false}" != "true" ]]; then
    if docker image inspect urumi-wordpress:latest >/dev/null 2>&1; then
      log "WordPress image already present; skipping build (set FORCE_REBUILD_WORDPRESS=true to rebuild)."
      return
    fi
  fi
  log "Building custom WordPress image..."
  if ! docker build -t urumi-wordpress:latest -f "$ROOT_DIR/Dockerfile" "$ROOT_DIR"; then
    die "Docker build failed."
  fi
}

import_k3d_image() {
  # Import image into k3d nodes (best-effort).
  if ! command -v k3d >/dev/null 2>&1; then
    return
  fi
  if [[ "${SKIP_IMAGE_IMPORT:-false}" == "true" ]]; then
    warn "Skipping k3d image import (SKIP_IMAGE_IMPORT=true)."
    return
  fi

  log "Importing image into k3d cluster: ${K3D_CLUSTER}"
  local import_ok="false"
  local retries="${K3D_IMPORT_RETRIES:-2}"
  for attempt in $(seq 1 "$retries"); do
    if k3d image import urumi-wordpress:latest -c "${K3D_CLUSTER}"; then
      import_ok="true"
      break
    fi
    warn "k3d image import failed (attempt ${attempt}/${retries}). Retrying..."
    sleep 2
  done
  if [[ "$import_ok" != "true" ]]; then
    warn "k3d image import failed. The cluster may try to pull from a registry."
  fi
}

ensure_sudo() {
  if sudo -n true >/dev/null 2>&1; then
    return 0
  fi
  warn "sudo is required to import images into k3s. You may be prompted for your password."
  sudo -v
}

import_k3s_image() {
  # Import image into k3s containerd (strict).
  if ! command -v k3s >/dev/null 2>&1; then
    die "k3s not found; cannot import WordPress image."
  fi
  if [[ "${SKIP_IMAGE_IMPORT:-false}" == "true" ]]; then
    warn "Skipping k3s image import (SKIP_IMAGE_IMPORT=true)."
    return
  fi
  if ! command -v docker >/dev/null 2>&1; then
    die "Docker is required to export the WordPress image for k3s."
  fi
  if ! docker image inspect urumi-wordpress:latest >/dev/null 2>&1; then
    die "Docker image urumi-wordpress:latest not found. Build the image first."
  fi
  if ! ensure_sudo; then
    die "sudo authorization failed; cannot import image into k3s."
  fi
  local tar="/tmp/urumi-wordpress.tar"
  log "Exporting WordPress image..."
  if ! docker save urumi-wordpress:latest -o "$tar"; then
    die "Docker save failed."
  fi
  log "Importing image into k3s containerd..."
  if ! sudo k3s ctr images import "$tar"; then
    rm -f "$tar"
    die "k3s image import failed."
  fi
  rm -f "$tar"
}
