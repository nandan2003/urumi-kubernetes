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
kubectl -n store-<id> get secret urumi-<id>-ecommerce-store-secrets \
  -o jsonpath='{.data.wp-admin-password}' | base64 -d
```

Admin user/email come from `WP_ADMIN_USER` / `WP_ADMIN_EMAIL` (defaults `admin` / `admin@example.com`).

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

Example:

```bash
STORE_BASE_DOMAIN=stores.example.com \
VALUES_FILE=../charts/ecommerce-store/values-prod.yaml \
STORAGE_CLASS=local-path \
go run .
```

## Notes
- Secrets are injected at install time by the orchestrator (no hardcoded secrets in repo).
- Namespace-per-store provides isolation and simplified teardown.
- Medusa is stubbed in Round 1 but the chart supports engine switching.

See `SYSTEM_DESIGN.md` for tradeoffs and reliability notes.
