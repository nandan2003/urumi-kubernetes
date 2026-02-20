# Kubernetes Templates for e-commerce Store

This directory contains the Helm templates responsible for provisioning and managing a complete e-commerce store stack. The architecture is designed for high availability, security isolation, and automated provisioning.

## Core Components

### Compute & Orchestration
- **`deployment.yaml`**: Manages the WordPress/WooCommerce application pods. It handles container lifecycle, horizontal scaling, and readiness/liveness probes to ensure traffic only hits healthy instances.
- **`mysql-statefulset.yaml`**: Deploys the MySQL database. Uses a `StatefulSet` rather than a Deployment to provide stable network identities and persistent disk attachment—essential for database consistency.
- **`medusa-stub.yaml`**: A conditional placeholder for the Medusa e-commerce engine. Currently deploys a stubbed Nginx service for architectural compatibility.

### Networking & Access
- **`service.yaml` & `mysql-service.yaml`**: Define internal `ClusterIP` services. They provide stable internal DNS endpoints (e.g., `store-mysql:3306`) so the application can communicate with the database reliably.
- **`ingress.yaml`**: The gateway. It uses the Kubernetes Ingress API to route external HTTP(S) traffic from a specific host (e.g., `nike.urumi.local`) to the application service.

### Data & State
- **`wordpress-pvc.yaml`**: A `PersistentVolumeClaim` that requests persistent block storage for the WordPress media library and themes, ensuring data survives pod restarts or node failures.
- **`secret.yaml`**: Securely stores sensitive credentials (DB passwords, admin logins). These are injected into containers as environment variables at runtime.

## Provisioning & Governance

### Initialization (Day 0)
- **`wpcli-job.yaml`**: A critical one-time `Job` that executes the store setup. It runs before the main application is fully live to perform database migrations, admin creation, and plugin activation.
- **`wpcli-configmap.yaml`**: The configuration repository for the provisioning job. It contains:
    - `setup.sh`: The master bootstrap script that orchestrates the WP-CLI install flow.
    - `products.sh`: A script for automated bulk product/catalog ingestion.
    - `urumi-campaign-tools.php`: A platform-specific utility plugin injected during setup.

### Resource & Security Policy
- **`limitrange.yaml`**: Enforces default CPU and Memory constraints on individual containers to prevent "noisy neighbor" behavior.
- **`resourcequota.yaml`**: Hard aggregate limits for the entire Namespace. This prevents a single store from exhausting the cluster's total capacity (CPU, RAM, or Storage).
- **`networkpolicy.yaml`**: Implements fine-grained isolation. It restricts network traffic so that only the Ingress can reach WordPress, and only WordPress can reach the Database, significantly reducing the attack surface.

## Internal Logic
- **`_helpers.tpl`**: A library of reusable Go template functions. It centralizes naming logic, label generation, and metadata tagging to ensure consistency across all resources in the stack.

---

## Lifecycle Execution Flow
1. **Namespace Creation**: The Orchestrator creates a dedicated namespace for the store.
2. **Resource Injection**: Helm applies these templates. Secrets and ConfigMaps are created first.
3. **Database Boot**: The MySQL StatefulSet initializes and becomes ready.
4. **Provisioning Job**: The `wpcli-job` triggers. It waits for the database, installs the WordPress core, activates WooCommerce, and disables "Coming Soon" mode.
5. **Application Live**: Once provisioning is successful, the WordPress Deployment probes pass, and the Ingress starts routing user traffic.
