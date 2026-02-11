# Requirements (Local + VPS)

This project uses the same stack locally and on VPS. The requirements below apply to both,
with minor environment-specific notes.

## Core requirements (both local and VPS)
- **Kubernetes cluster**: k3d / kind / minikube (local) or k3s (VPS)
- **kubectl** (matches your cluster version)
- **Helm 3**
- **Go 1.22+** (to run the orchestrator)
- **Node.js 20+** (to run the dashboard)

## Local-only
- **Docker Engine** (required for k3d/kind and image builds)
- Optional: `ss` or `lsof` (for port checks)

## VPS-only (Azure or other)
- Ubuntu 22.04 LTS (recommended)
- Open ports: **22**, **80**, **443**, **8080** (API), **5173** (dashboard)
- Ingress controller: **Traefik (k3s default)** or **NGINX**
- Persistent storage class: `local-path` (single node) or `longhorn`
- **Docker Engine** (required to build the custom WordPress image for k3s)

## Optional (nice to have)
- `python3` (for product script generation)
- `rg` (ripgrep) for faster search
