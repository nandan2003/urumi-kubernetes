# scripts/ overview

These helper scripts are sourced by `start.sh`. They are not meant to be run directly.

## Entry point
- `start.sh` is the only user-facing entry point. Do not execute these modules directly.

## Modules
- `lib.sh` — logging, retries, kubectl wrapper.
- `cluster.sh` — preflight checks, cluster lifecycle, ingress readiness, ingress class detection.
- `images.sh` — build/import WordPress image.
- `ports.sh` — admin port-forward management with PID tracking.
- `cleanup.sh` — process cleanup, namespace cleanup, nuclear reset.
- `products.sh` — sample CSV handling + products.sh generation for WP-CLI job.
- `rbac.sh` — ServiceAccount kubeconfig setup for orchestrator.

## Execution flow (high level)
1. Preflight checks (Docker/k3d).
2. Cluster bootstrap + kubeconfig + ingress readiness.
3. Products CSV + WP-CLI products script generation.
4. Image build + import to k3d.
5. Cleanup (processes + stale namespaces).
6. Orchestrator + dashboard start.
7. Admin port-forward watcher loop.

## Common env vars used
- `K3D_CLUSTER`, `KUBECONFIG_FILE`, `INGRESS_CLASS`, `STORAGE_CLASS`, `VALUES_FILE`
- `CLEANUP_STORES`, `STUCK_MINUTES`, `NUCLEAR_RESET`
- `PREFLIGHT_RETRIES`, `PREFLIGHT_SLEEP`

## Failure handling notes
- Preflight failures exit early with guidance (Docker/k3d).
- RBAC setup is best-effort; falls back to admin kubeconfig.
- Image import failures are non-fatal (cluster may pull from registry).

## Notes
- Keep all modules idempotent and safe to source multiple times.
- Prefer adding new functionality as a module instead of growing `start.sh`.
