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

## Scaling considerations (future work)
These are **scale risks** for large tenant counts (not current requirements) and how the design would evolve.

### 1) State persistence bottleneck (stores.json)
- **Current behavior:** every update rewrites the entire `stores.json` file (see `store_manager.go`).
- **Risk at high scale:** disk I/O and global mutex contention increase with store count; status updates become slow.
- **Fix path:** replace the JSON file with a database (PostgreSQL or similar) and update a single row per store.

### 2) Reconcile loop complexity (O(N) polling)
- **Current behavior:** `reconcile.go` iterates all stores periodically.
- **Risk at high scale:** latency grows linearly with store count; “Ready/Failed” status updates lag.
- **Fix path:** switch to event‑driven reconciliation (Kubernetes informers / watch API) or a queue.

### 3) Kubernetes control‑plane limits (etcd object growth)
- **Current behavior:** one namespace per store; each store creates multiple K8s objects.
- **Risk at very high scale:** etcd size limits and API latency become a bottleneck.
- **Fix path:** **multi‑cluster** sharding (fleet of clusters) with a control plane that assigns tenants per cluster.

### 4) Ingress controller scale
- **Current behavior:** nginx ingress updates config on every new host.
- **Risk at high route counts:** reloads become slow and can impact availability.
- **Fix path:** use a gateway that stores routes in a data plane (Envoy/Cilium/Kong with dynamic config) or shard by cluster.

### 5) Per‑store database pods
- **Current behavior:** each store has its own MySQL StatefulSet.
- **Risk at high scale:** pod count and memory usage become prohibitive.
- **Fix path:** migrate to managed DBs and/or multi‑tenant schema with strict isolation policies.
