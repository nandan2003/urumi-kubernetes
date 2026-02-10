# Orchestrator (Go)

The orchestrator is the control plane for store lifecycle. It exposes an HTTP API,
persists store state to disk, provisions with Helm, and reconciles status in the background.

## Quick start
```bash
cd orchestrator
go run .
```

## API endpoints
- `GET /healthz` — health check
- `GET /api/stores` — list stores
- `POST /api/stores` — create store
- `GET /api/stores/:id` — get store
- `DELETE /api/stores/:id` — delete store
- `GET /api/activity` — recent lifecycle events
- `GET /api/metrics` — aggregate metrics

## Key environment variables
- `ORCH_ADDR` (default `:8080`)
- `CHART_PATH` (default `../charts/ecommerce-store`)
- `VALUES_FILE` (default `../charts/ecommerce-store/values-local.yaml`)
- `STORE_BASE_DOMAIN` (default `127.0.0.1.nip.io`)
- `INGRESS_CLASS` (auto-detected if empty)
- `STORAGE_CLASS` (required if no default StorageClass)
- `WP_ADMIN_USER`, `WP_ADMIN_EMAIL`, `WP_ADMIN_PASSWORD` (password optional)
- `PROVISION_TIMEOUT`
- `MAX_CONCURRENT_PROVISIONS`
- `MAX_STORES_TOTAL`, `MAX_STORES_PER_IP`
- `RATE_LIMIT_MAX`, `RATE_LIMIT_WINDOW`
- `MAX_PROVISION_RETRIES`, `PROVISION_RETRY_BACKOFF`
- `AUDIT_LOG_FILE`, `ACTIVITY_LOG_FILE`

## Data & logs
- `data/stores.json` — persistent store state
- `data/audit.log` — create/delete audit trail
- `data/activity.log` — lifecycle events

## Provisioning flow (high level)
1. Create request is validated and stored.
2. Provisioning runs asynchronously via Helm.
3. Background reconcile updates status (Ready/Failed).
4. Delete removes the Helm release and namespace.

## Requirements
The orchestrator uses the current kubeconfig and must have permission to:
- create/delete namespaces
- create/update resources inside `store-*` namespaces
