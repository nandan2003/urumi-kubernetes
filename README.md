# Urumi Store Provisioning Platform - Round 1 (Kubernetes)

This repo implements a **Kubernetes‑native store provisioning platform** that runs locally and on an Azure VM using the **same Helm chart** with different values files. It is built as a part of `Urumi SDE Internship` hiring process.

---

Apologies for not recording this video with including my voice due to unavoidable circumstances: [Demo Video Link](!https://drive.google.com/file/d/17GWVXwYrA4Odm6HHREKsBZ2EoxzCOBEC/view?usp=sharing)

---

![Architecture Diagram](image3x.png)

---

## 1) Problem statement (Round 1)
Build a small **store provisioning platform** that works on local Kubernetes and can run in production (k3s on a VPS) **with configuration changes only** (via Helm values).

**Scope implemented in this repo**
- **WooCommerce** engine is fully implemented (WordPress + WooCommerce + auto provisioning via WP‑CLI job).
- **Medusa** is **stubbed** (placeholder deployment + service) to keep the architecture ready for a future engine.

---

## 2) User story coverage
**Supported today**
- Open a React dashboard.
- View existing stores and their status.
- Create a new store (WooCommerce).
- Provision multiple stores (concurrently, with concurrency limits).
- See status + URL + timestamps.
- Delete a store and clean up all resources.

**Engines**
- ✅ **WooCommerce** (fully working end‑to‑end)
- ⚠️ **Medusa** (stub only in Round 1; architecture supports a second engine later)

---

## 3) Definition of Done (WooCommerce)
A provisioned store supports placing an order end‑to‑end:
1. Open storefront URL
2. Add product to cart
3. Checkout using COD
4. Verify order in WooCommerce admin

---

## 4) Architecture & responsibilities (high level)
**Components**
- **Dashboard (React)**: UI to create/list/delete stores and show status.
- **Orchestrator (Go)**: HTTP API + Helm SDK provisioning + reconciliation loop.
- **Helm chart (`charts/ecommerce-store`)**: WordPress + MySQL + WP‑CLI job + K8s resources.

**Key files**
- `dashboard/` — React UI
- `orchestrator/` — API + store manager + Helm provisioning
- `charts/ecommerce-store/` — Helm chart + values for local/prod
- `start.sh` — local one‑command start (k3d)
- `start-vps.sh` — VPS wrapper (k3s)
- `setup.sh` — optional dependency installer (Linux only)

---

## 5) Kubernetes + Helm requirements mapping
**Requirement** → **Where it’s implemented**
- Local Kubernetes (k3d/kind/minikube) → `start.sh` (k3d) + Helm chart
- Production‑like VPS (k3s) → `start-vps.sh`, `values-prod.yaml`
- Helm required (no Kustomize) → `orchestrator/provisioner.go` (Helm SDK)
- K8s‑native provisioning (Deployments/StatefulSets/Jobs/etc.) → `charts/ecommerce-store/templates/*`
- Multi‑store isolation (namespace per store) → `orchestrator/store_manager.go` + Helm installs into `store-<id>`
- Persistent DB storage → `mysql-statefulset.yaml` + PVC templates
- Ingress for stable URLs → `ingress.yaml` with host‑based routing
- Readiness/liveness → `deployment.yaml`/`mysql-statefulset.yaml`
- Clean teardown → `orchestrator/cleanup.go` + Helm uninstall + namespace delete
- No hardcoded secrets → secrets generated in `orchestrator/provisioner.go` and stored in K8s `Secret`

---

## 6) Prerequisites
**Local (k3d default)**
- Docker
- kubectl
- Helm
- k3d
- Go **1.25.x** (from `orchestrator/go.mod`)
- Node **20.x** (Vite requirement)

**VPS (k3s)**
- k3s
- kubectl
- Go **1.25.x**
- Node **20.x**
- Docker (required to build/import the WordPress image)

### Optional setup helper
`setup.sh` checks and (optionally) installs prerequisites on Linux:
```bash
./setup.sh --mode both          # dry-run (safe)
./setup.sh --apply --mode both  # install (prompts before changes)
```
Windows: use **WSL2** (Ubuntu) and run the setup inside WSL.

---

## 7) Local setup (k3d, recommended)
This is the **fastest, supported local path**.

### 7.1 Install ingress‑nginx once
`start.sh` expects an ingress controller to exist. Install nginx ingress once per cluster:
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace
```

### 7.2 One‑command local start
```bash
./start.sh
```
This will:
- create/start a **k3d** cluster (`urumi-local`)
- build & import the `urumi-wordpress` image
- start **orchestrator** and **dashboard**

**Local URL pattern**
- `http://<store-id>.127.0.0.1.nip.io` (default)

### 7.3 Optional overrides
```bash
INGRESS_CLASS=nginx \
STORAGE_CLASS=local-path \
VALUES_FILE=charts/ecommerce-store/values-local.yaml \
./start.sh
```

---

## 8) VPS setup (k3s)
### 8.1 Install k3s (example)
```bash
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
```

### 8.2 Install nginx ingress
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace
```

> If k3s Traefik is enabled, either disable it or switch `INGRESS_CLASS=traefik`.

### 8.3 Open ports
- **80, 443, 8080, 5173, 6443** on your VM firewall / security group.

### 8.4 Start on VPS
```bash
VM_PUBLIC_IP=<your-public-ip> ./start-vps.sh
```
Defaults:
- `BASE_DOMAIN=<VM_PUBLIC_IP>.nip.io`
- `INGRESS_CLASS=nginx`
- `VALUES_FILE=charts/ecommerce-store/values-prod.yaml`

**VPS URL pattern**
- Dashboard: `http://dashboard.<VM_PUBLIC_IP>.nip.io:5173`
- Store: `http://<store-id>.<VM_PUBLIC_IP>.nip.io`

---

## 9) Create a store
**Via dashboard**: click **Create Store** → choose WooCommerce.

**Via API**:
```bash
curl -X POST http://localhost:8080/api/stores \
  -H 'Content-Type: application/json' \
  -d '{"name":"nike","engine":"woocommerce"}'
```

---

## 10) Verify resources after create
```bash
ID=nike
NS="store-$ID"
REL="urumi-$ID-ecommerce-store"

kubectl get ns | grep "$NS"
kubectl -n "$NS" get all
kubectl -n "$NS" get pvc
kubectl -n "$NS" get ing
kubectl -n "$NS" get jobs
kubectl -n "$NS" logs "job/$REL-wpcli" --tail=200
```

Ingress host check:
```bash
curl -I -H "Host: ${ID}.<base-domain>" http://127.0.0.1
```

---

## 11) Place an order (Definition of Done)
1. Open `http://<store-id>.<base-domain>`
2. Add product to cart
3. Checkout (COD is enabled by WP‑CLI job)
4. Verify order in WP admin: `http://<store-id>.<base-domain>/wp-admin`

---

## 12) Admin credentials (WooCommerce)
```bash
kubectl -n store-<id> get secret urumi-<id>-ecommerce-store-secrets \
  -o jsonpath='{.data.wp-admin-password}' | base64 -d; echo
```
Defaults:
- Admin user: `admin`
- Admin email: `admin@example.com`
- Password is **generated per store** (stored in Secret)

---

## 13) Database inspection (MySQL)
```bash
ID=<id>
NS="store-$ID"
REL="urumi-$ID-ecommerce-store"

MYSQL_POD=$(kubectl -n "$NS" get pods -l app.kubernetes.io/component=mysql -o jsonpath='{.items[0].metadata.name}')
ROOT_PW=$(kubectl -n "$NS" get secret "$REL-secrets" -o jsonpath='{.data.mysql-root-password}' | base64 -d)

kubectl -n "$NS" exec "$MYSQL_POD" -- \
  mysql -uroot -p"$ROOT_PW" -e "USE wordpress; SHOW TABLES;"
```

Schema (all columns):
```bash
kubectl -n "$NS" exec "$MYSQL_POD" -- \
  mysql -uroot -p"$ROOT_PW" -e "
SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE
FROM information_schema.columns
WHERE table_schema='wordpress'
ORDER BY TABLE_NAME, ORDINAL_POSITION;"
```

---

## 14) Delete a store (and verify cleanup)
```bash
curl -X DELETE http://localhost:8080/api/stores/nike

kubectl get ns | grep store-nike
helm list -A | grep urumi-nike
kubectl get pvc -A | grep nike
```

---

## 15) Local‑to‑VPS production story
**Same chart, different values**
- Local values: `charts/ecommerce-store/values-local.yaml`
- VPS values: `charts/ecommerce-store/values-prod.yaml`

**What changes**
- Ingress class (`INGRESS_CLASS`)
- Base domain (`STORE_BASE_DOMAIN`)
- Storage class (`STORAGE_CLASS`)
- NetworkPolicy defaults (off locally, on in prod)
- Resource quotas (higher on VPS)

---

## 16) System design & tradeoffs (short)
**Architecture choice**
- Helm SDK inside Go orchestrator for idempotent installs and lifecycle control.
- Namespace‑per‑store isolation for clean teardown and blast‑radius control.

**Idempotency / failure handling**
- Requests are validated; create/delete are logged to `data/audit.log`.
- Provisioning runs async; status updated by reconcile loop.
- Helm install uses `Wait` + `WaitForJobs` to ensure store is ready.

**Cleanup**
- Delete triggers Helm uninstall + namespace deletion.
- Cleanup helper removes stuck namespaces/finalizers (best effort).

**Production changes**
- DNS/ingress domain, storage class, and NetworkPolicy via values.
- Same chart used for local and VPS.

---

## 17) Security posture (baseline)
- **Secrets**: generated per store and stored only in Kubernetes Secrets.
- **RBAC**: optional ServiceAccount flow (`USE_RBAC=true`); VPS defaults to admin kubeconfig.
- **NetworkPolicy**: enabled in `values-prod.yaml` (ingress allowlist + DNS + DB).
- **Public exposure**: only Ingress is public; MySQL stays internal.

---

## 18) Scaling plan (horizontal)
- **API/orchestrator**: stateless → multiple replicas behind a Service.
- **Dashboard**: static frontend → multiple pods / CDN.
- **Provisioning throughput**: increase `MAX_CONCURRENT_PROVISIONS`, add worker queues.
- **Stateful constraints**: MySQL is per‑store StatefulSet; for scale, migrate to managed DB.

---

## 19) Abuse prevention & guardrails
Implemented in orchestrator (configurable via env):
- Rate limiting per IP (`RATE_LIMIT_MAX`, `RATE_LIMIT_WINDOW`)
- Max stores total (`MAX_STORES_TOTAL`)
- Max stores per IP (`MAX_STORES_PER_IP`)
- Provisioning timeout (`PROVISION_TIMEOUT`)
- Audit log (`data/audit.log`) + activity log (`data/activity.log`)

---

## 20) Helm upgrade / rollback (per store)
```bash
helm upgrade urumi-<id> charts/ecommerce-store \
  -n store-<id> \
  -f charts/ecommerce-store/values-local.yaml \
  --reuse-values \
  --atomic --wait --timeout 10m

helm history urumi-<id> -n store-<id>
helm rollback urumi-<id> <REVISION> -n store-<id> --wait --timeout 10m
```

---

## 21) Known limitations (Round 1)
- Medusa is a **stub** (not fully implemented).
- No multi‑node DB or multi‑AZ persistence (single‑node k3d/k3s).
- TLS is not automated in this repo (cert‑manager annotations exist but not configured).

---

## 22) Useful references (in repo)
- `SYSTEM_DESIGN.md` — short architecture note
- `orchestrator/README.md` — API + config details
- `charts/ecommerce-store/` — Helm chart templates

