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

## VPS runbook (Azure k3s + NGINX + nip.io)
Use this if you are deploying to a single Azure VM and want stable nip.io URLs.

### 0) VM baseline
- Size: Standard_D8as_v4 (smaller works for demos).
- OS: Ubuntu 22.04 LTS.
- Public IP: Static.
- Open ports: 22, 80, 443, 5173 (dashboard), 8080 (API). Optional: 6443 for remote kubectl.

### 1) SSH
```bash
ssh <user>@<public-ip>
```

### 2) OS prep
```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
sudo apt-get update -y
sudo apt-get install -y curl ca-certificates
```

### 3) Install k3s without Traefik
```bash
curl -sfL https://get.k3s.io | sh -s - --disable traefik --write-kubeconfig-mode 644
kubectl get nodes
```

### 4) Install Helm + NGINX ingress
```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace
kubectl get ingressclass
```

### 5) Clone repo
```bash
git clone https://github.com/nandan2003/urumi-kubernetes.git
cd urumi-kubernetes
```

### 6) Update repo (if already cloned)
```bash
git pull
```

### 7) Install Go 1.22 (required for orchestrator)
```bash
cd /tmp
curl -fsSL https://go.dev/dl/go1.22.6.linux-amd64.tar.gz -o go1.22.6.linux-amd64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go1.22.6.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
source ~/.bashrc
go version
```

### 8) Install Node 20 for dashboard
```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
node -v
npm -v
```

### 9) Install Docker (required for the custom WordPress image)
```bash
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
newgrp docker
docker version
```

### 10) One-click start (recommended)
```bash
cd ~/urumi-kubernetes
VM_PUBLIC_IP=<public-ip> ./start-vps.sh
```
Open:
```
http://dashboard.<public-ip>.nip.io:5173
```

### 11) Create a store
From the dashboard:
- Name: `nike`
- Engine: WooCommerce

Expected URL:
```
http://nike.<public-ip>.nip.io
```

### 12) Admin password retrieval
```bash
kubectl -n store-nike get secret urumi-nike-ecommerce-store-secrets \
  -o jsonpath='{.data.wp-admin-password}' | base64 -d
```

### 13) If you see 404
- Wait 1–2 minutes (Ingress propagation).
- Check ingress:
```bash
kubectl -n ingress-nginx get pods
kubectl get ing -A
```

### 14) If the dashboard shows API Offline
- From your PC:
```bash
curl http://<public-ip>:8080/healthz
```
- Ensure Azure NSG allows inbound **8080** and **5173**.

Manual run (debug):
```bash
cd orchestrator
STORE_BASE_DOMAIN=<public-ip>.nip.io \
VALUES_FILE=../charts/ecommerce-store/values-prod.yaml \
INGRESS_CLASS=nginx \
STORAGE_CLASS=local-path \
go run .

cd ../dashboard
VITE_API_BASE=http://<public-ip>:8080 npm install
VITE_ALLOWED_HOSTS=dashboard.<public-ip>.nip.io,<public-ip>.nip.io \
VITE_API_BASE=http://<public-ip>:8080 \
npm run dev -- --host 0.0.0.0 --port 5173
```
```

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
