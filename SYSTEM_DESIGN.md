# System Design & Tradeoffs

## Architecture
- **Dashboard (React)**: lists stores, creates new stores, deletes stores. Polls `/api/stores` for status.
- **Orchestrator (Go + Helm SDK)**: validates requests, writes store state to a local JSON file, provisions via Helm into a namespace-per-store, and updates status asynchronously.
- **Workloads (Helm chart)**: WordPress + MySQL + WP-CLI Job. The Job automates WooCommerce setup and seeds products from `charts/ecommerce-store/files/sample-products.csv`.

## Idempotency & failure handling
- Store IDs are unique; attempts to create an existing ID are rejected.
- Provisioning is async. The API returns `Provisioning` immediately while Helm runs in a goroutine.
- The Helm install uses `Wait=true` and `WaitForJobs=true`. If the WP-CLI job fails, the store is marked `Failed`.
- Deletion first uninstalls the Helm release then deletes the namespace. Namespace deletion is the cleanup guarantee.
- Provisioning is bounded by a timeout (`PROVISION_TIMEOUT`).
- Provisioning retries are guarded and limited (`MAX_PROVISION_RETRIES` + `PROVISION_RETRY_BACKOFF`).

## Isolation & security posture
- Namespace-per-store and per-namespace `ResourceQuota` and `LimitRange`.
- Secrets generated at request time and injected into a Kubernetes Secret. No hardcoded passwords in the repo.
- NetworkPolicy is enabled in `values-prod.yaml` (prod only). Allowlist the ingress namespace:
  - nginx -> `ingress-nginx`
  - traefik -> `kube-system`
- Per-namespace RBAC: the orchestrator runs with a ServiceAccount that has cluster-scope permissions
  only for namespaces + discovery, and it creates a RoleBinding inside each `store-*` namespace for
  the resources it needs. `start.sh` auto-applies the RBAC manifest and falls back to admin kubeconfig
  if needed.

## Abuse prevention & guardrails
- Rate limiting for create/delete requests (per IP).
- Quotas: max stores total + max stores per IP.
- Audit log written to `orchestrator/data/audit.log`.

## Observability
- Activity log written to `orchestrator/data/activity.log` and exposed via `GET /api/activity`.
- Dashboard shows recent activity + per-store provisioning duration.
- Failure reasons are surfaced via `store.error`.
- Metrics endpoint `GET /api/metrics` provides aggregate counts + avg/p95 provisioning time.

## Upgrade / rollback plan
- Each store is a Helm release (`urumi-<id>`) scoped to its namespace.
- Upgrades are performed per store with `helm upgrade --reuse-values --atomic`.
- Rollbacks use `helm rollback` to a previous revision (captured by `helm history`).

## Local-to-prod portability
- The chart is identical across environments; only values files change.
- Local: `values-local.yaml` with low resource requests.
- Prod: `values-prod.yaml` with higher defaults and optional TLS annotations.
- `STORE_BASE_DOMAIN`, `INGRESS_CLASS`, and `STORAGE_CLASS` are injected via orchestrator env vars.

## Tradeoffs
- State is persisted in a local JSON file rather than a database to keep Round 1 scope focused.
- Medusa is stubbed in Round 1 but the chart supports engine switching.
- RBAC hardening is not yet applied; the orchestrator assumes a kubeconfig with namespace create/delete access.
