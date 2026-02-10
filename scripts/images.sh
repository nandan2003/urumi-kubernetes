#!/usr/bin/env bash
# Image build/import for local k3d.

build_wordpress_image() {
  # Build a local WordPress image for faster installs.
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
