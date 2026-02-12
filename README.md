# Urumi Store Provisioning Platform (Round 1)

This repo implements a Kubernetes-native store provisioning platform that works on local clusters and production-like k3s using the same Helm chart (different values files).

## What you get
- React dashboard to create/list/delete stores.
- Go orchestrator API that provisions stores via Helm SDK (namespace-per-store).
- WooCommerce engine fully automated with WP-CLI job (Medusa stub included). WordPress image pinned to 6.9.1 for WooCommerce compatibility.
- Helm chart with PVCs, probes, Ingress, Secrets, ResourceQuota, LimitRange.
- Auto-import of sample products from `charts/ecommerce-store/files/sample-products.csv`.

## Architecture (high-level)
- **Dashboard (React)** -> calls **Orchestrator API**
- **Orchestrator (Go)** -> Helm SDK installs chart into dedicated namespace
- **Helm chart** -> WordPress + MySQL + WP-CLI post-install job

## Prerequisites
- Kubernetes cluster: kind / k3d / minikube (k3s for prod)
- `kubectl`, `helm`, `go`, `node`/`npm`
- Ingress controller (nginx recommended)

## Local setup (kind example)
1. Create a kind cluster with host port 80/443 mapped (so nip.io hosts resolve locally):

```bash
cat <<'KIND' > /tmp/kind.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
      - containerPort: 443
        hostPort: 443
KIND
kind create cluster --config /tmp/kind.yaml
```

2. Install nginx ingress:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace
```

3. Run orchestrator API:

```bash
cd orchestrator
go run .
```

Optional env vars:
- `STORE_BASE_DOMAIN=127.0.0.1.nip.io`
- `VALUES_FILE=../charts/ecommerce-store/values-local.yaml`
- `INGRESS_CLASS=nginx`
- `STORAGE_CLASS=local-path` (required if your cluster has no default StorageClass)

4. Run dashboard:

```bash
cd dashboard
npm install
VITE_API_BASE=http://localhost:8080 npm run dev
```

Open the dashboard at `http://localhost:5173`.

## One-command local start

```bash
./start.sh
```

This starts the orchestrator + dashboard, detects an ingress base domain, and prints URLs. Pass a store id to enable WP admin port-forwarding:

```bash
./start.sh store-one
```

## Create a store
Use the dashboard or POST directly:

```bash
curl -X POST http://localhost:8080/api/stores \
  -H 'Content-Type: application/json' \
  -d '{"name":"Store One","engine":"woocommerce"}'
```

The store URL will look like:
- `http://store-one.127.0.0.1.nip.io`

If provisioning fails due to storage, confirm your StorageClass:

```bash
kubectl get storageclass
```

## Definition of Done (WooCommerce)
1. Open storefront URL.
2. Add the seeded product to cart.
3. Checkout using COD (enabled via WP-CLI job).
4. Confirm order in WP admin.

Retrieve admin password (replace `<id>` with the store id from the dashboard):

```bash
KUBECONFIG=.kube/k3d-urumi-local.yaml kubectl -n store-<id> get secret urumi-<id>-ecommerce-store-secrets \
  -o jsonpath='{.data.wp-admin-password}' | base64 -d
```

Admin user/email come from `WP_ADMIN_USER` / `WP_ADMIN_EMAIL` (defaults `admin` / `admin@example.com`).
The admin password is generated per store and stored in the Kubernetes Secret. You can
retrieve the initial password with:

```bash
kubectl -n store-<id> get secret urumi-<id>-ecommerce-store-secrets \
  -o jsonpath='{.data.wp-admin-password}' | base64 -d
```

## Database inspection (MySQL)
Replace `<id>` with your store id (e.g., `nike`).

### Full database dump (everything)
```bash
ID=<id>
NS="store-$ID"
REL="urumi-$ID-ecommerce-store"

MYSQL_POD=$(kubectl -n "$NS" get pods -l app.kubernetes.io/component=mysql -o jsonpath='{.items[0].metadata.name}')
ROOT_PW=$(kubectl -n "$NS" get secret "$REL-secrets" -o jsonpath='{.data.mysql-root-password}' | base64 -d)

kubectl -n "$NS" exec "$MYSQL_POD" -- \
  mysqldump -uroot -p"$ROOT_PW" --single-transaction --routines --triggers --events wordpress
```

### List all tables
```bash
kubectl -n "$NS" exec "$MYSQL_POD" -- \
  mysql -uroot -p"$ROOT_PW" -e "USE wordpress; SHOW TABLES;"
```

### List all columns (every table)
```bash
kubectl -n "$NS" exec "$MYSQL_POD" -- \
  mysql -uroot -p"$ROOT_PW" -e "
SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT
FROM information_schema.columns
WHERE table_schema='wordpress'
ORDER BY TABLE_NAME, ORDINAL_POSITION;"
```

### Schema-only dump
```bash
kubectl -n "$NS" exec "$MYSQL_POD" -- \
  mysqldump -uroot -p"$ROOT_PW" --no-data wordpress
```

If you change the password in WordPress, the secret still contains the original value.

To reset the admin password manually (example):

```bash
kubectl -n store-<id> exec deploy/urumi-<id>-ecommerce-store-wordpress \
  -- wp user update admin --user_pass='<newpass>'
```

## Sample products
The CSV used to seed products is stored at:
`charts/ecommerce-store/files/sample-products.csv`

## Delete a store
Use the dashboard or:

```bash
curl -X DELETE http://localhost:8080/api/stores/store-one
```

This removes the Helm release and namespace (clean teardown).

## Production-like deployment (k3s)
- Install nginx ingress (or use Traefik if preferred).
- Use `values-prod.yaml` and set:
  - `STORE_BASE_DOMAIN` to your public domain (wildcard DNS).
  - `STORAGE_CLASS` to your CSI class.
  - `INGRESS_CLASS` to your controller.
  - `networkPolicy.allowIngressFromNamespace` to match your ingress namespace:
    - nginx -> `ingress-nginx`
    - traefik -> `kube-system`
  - `networkPolicy.allowIngressFromSameNamespace`: allow intra-namespace access to WordPress (safe default).
  - `networkPolicy.allowEgressToInternet`: keep `false` unless you need outbound HTTP/HTTPS (e.g., updates).

Example:

```bash
STORE_BASE_DOMAIN=stores.example.com \
VALUES_FILE=../charts/ecommerce-store/values-prod.yaml \
STORAGE_CLASS=local-path \
go run .
```

## Production story (local → VPS parity)
This project runs the **same Helm chart** locally and on VPS. Only the **values file and env vars** change.

### Parity model
- **Chart**: `charts/ecommerce-store` (same for local + VPS)
- **Local values**: `values-local.yaml`
- **VPS values**: `values-prod.yaml`
- **Orchestrator**: same binary + Helm SDK flow

### What changes between local and VPS (values/env)
- **Ingress class**:
  - Local: often nginx in k3d/kind (`INGRESS_CLASS=nginx`)
  - VPS: nginx in k3s (`INGRESS_CLASS=nginx`)
- **Base domain**:
  - Local: `127.0.0.1.nip.io`
  - VPS: `<public-ip>.nip.io` or wildcard DNS
- **Storage class**:
  - Local: `local-path` (k3d/kind default)
  - VPS: `local-path` or CSI (Longhorn, etc.)
- **NetworkPolicy**:
  - Local: usually off
  - VPS: enabled with ingress allowlist

### Ingress exposure on VPS
Ensure nginx is reachable externally:
- **Ports open**: 80/443 on VM security group/NSG
- **Ingress service**: `ingress-nginx-controller` must be exposed (LoadBalancer/NodePort)
- **DNS**: wildcard record to VM IP (or nip.io)

### Secrets strategy
Secrets are generated per store at provision time and stored in Kubernetes Secrets.
No secrets are hardcoded in source control.

### Clean teardown
Store deletion removes the Helm release and deletes the namespace. Zombie finalizers
are cleaned if necessary.

### Upgrade/Rollback
Each store is a Helm release (`urumi-<id>`). Upgrades and rollbacks use Helm with `--atomic`
and `--reuse-values` to preserve data.

## Notes
- Secrets are injected at install time by the orchestrator (no hardcoded secrets in repo).
- Namespace-per-store provides isolation and simplified teardown.
- Medusa is stubbed in Round 1 but the chart supports engine switching.

## Abuse prevention controls (simple defaults)
The orchestrator enforces lightweight abuse controls:

- **Rate limiting** per IP for create/delete (defaults: 15 requests/minute)
- **Max stores total** (default: 20)
- **Max stores per IP** (default: 5)
- **Provision timeout** (default: 8 minutes)
- **Audit log** of create/delete in `orchestrator/data/audit.log`

Override via env vars:

```bash
MAX_STORES_TOTAL=20 \
MAX_STORES_PER_IP=5 \
RATE_LIMIT_MAX=15 \
RATE_LIMIT_WINDOW=1m \
MAX_PROVISION_RETRIES=1 \
PROVISION_RETRY_BACKOFF=10s \
PROVISION_TIMEOUT=8m \
./start.sh
```

## Observability (lightweight)
- **Activity log** endpoint: `GET /api/activity` (shown in dashboard)
- **Metrics** endpoint: `GET /api/metrics` (avg/p95 provisioning time)
- **Audit log**: `orchestrator/data/audit.log` (create/delete events)
- **Activity log**: `orchestrator/data/activity.log` (created/ready/failed/deleted)
- **Provisioning duration** shown per store in the dashboard

## Upgrade / rollback plan (per store)
Each store is a Helm release named `urumi-<id>` in namespace `store-<id>`. Upgrades are
performed per store. Use `--atomic` to auto-rollback on failures.

### Upgrade (safe)
```bash
helm upgrade urumi-<id> charts/ecommerce-store \
  -n store-<id> \
  -f charts/ecommerce-store/values-local.yaml \
  --reuse-values \
  --atomic \
  --wait \
  --timeout 10m
```

### Rollback (safe)
```bash
helm history urumi-<id> -n store-<id>
helm rollback urumi-<id> <REVISION> -n store-<id> --wait --timeout 10m
```

Notes:
- `--reuse-values` keeps existing secrets, PVCs, and store settings.
- For production, use `values-prod.yaml` instead of `values-local.yaml`.

## RBAC (per-namespace least privilege)
`./start.sh` automatically applies the RBAC manifest and runs the orchestrator with a
ServiceAccount when possible. It falls back to the admin kubeconfig if that fails.

The ServiceAccount gets only cluster-scope permissions for namespaces + discovery,
and per-store permissions are granted via RoleBinding inside each `store-*` namespace.

The generated kubeconfig is stored at `.kube/orchestrator-sa.yaml`.

See `SYSTEM_DESIGN.md` for tradeoffs and reliability notes.
