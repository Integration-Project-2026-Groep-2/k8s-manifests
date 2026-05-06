# Kubernetes Manifests

This repository contains the Kubernetes manifests for the integration platform.
It is set up for GitOps with Argo CD and uses Kustomize overlays for dev and prod environments.

## What is here

```text
.
├── base/               Shared Kustomize base for workloads, gateway class, and policies
├── argocd/              Argo CD App-of-Apps and child Applications
├── apps/                Team services and their deployments
├── gateway/             NGINX Gateway Fabric controller values and Gateway API config
├── headlamp/            Standalone Headlamp cluster UI (non-Argo, separate namespace)
├── infrastructure/      Elasticsearch, Kibana, RabbitMQ
├── network-policies/    Default deny and workload network rules
├── overlays/            dev and prod Kustomize overlays
└── base/secrets/        Local .env templates and destination-cluster secret bootstrap docs
```

## Prerequisites

Before starting the Kubernetes cluster, ensure you have:

1. **Kubernetes Cluster**: A running Kubernetes cluster (v1.26+)
2. **kubectl**: Configured and connected to your cluster
3. **Helm**: Version 3.0+
4. **git**: For cloning this repository
5. **Kustomize**: Included with kubectl, used for deploying manifests
6. **kubeseal CLI**: Required to generate SealedSecret manifests

## Getting Started

### Step 0: Setup Cluster using Kubeadm

```bash
sudo kubeadm init --pod-network-cidr=192.168.0.0/16 --apiserver-bind-port 6443 --control-plane-endpoint=example.com
```

### Step 1: Install Core Infrastructure Components

Install the required controllers and admission systems:

#### 1.1 Install Gateway API CRDs

```bash
kubectl kustomize "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=v2.5.1" | kubectl apply -f -
```

#### 1.2 Install Sealed Secrets Controller (Helm preferred)

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

helm install sealed-secrets sealed-secrets/sealed-secrets \
  -n kube-system \
  --set fullnameOverride=sealed-secrets

# Verify it is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets
```

If you cannot use Helm, you can apply the controller manifest directly:

```bash
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml
```

#### 1.3 Install Argo CD

```bash
kubectl create namespace argocd
kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for Argo CD to be ready
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
```

If your kubectl version does not support server-side apply, install Argo CD with Helm instead or apply the manifests in smaller chunks. The full install bundle includes large CRDs, and client-side `kubectl apply` can exceed the annotation size limit.

#### 1.4 Install NGINX Gateway Fabric and Gateway Resources

Install the NGINX Gateway Fabric controller and define the Gateway API resources. The gateway runs in the `main-gateway` namespace on **NodePort 30097**.

```bash
# Install the NGINX Gateway Fabric controller with Helm
helm install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  -n main-gateway --create-namespace \
  -f gateway/gateway-controller-values.yaml

# Apply gateway resources (GatewayClass, Gateway, HTTPRoutes)
kubectl apply -k gateway/

# Apply Argo CD resources (namespace, ReferenceGrant for cross-namespace routing, app-of-apps)
kubectl apply -k argocd/

# Verify the controller and gateway are running
kubectl get pods -n main-gateway -l app.kubernetes.io/name=nginx-gateway-fabric
kubectl get gatewayclass,gateway -n main-gateway
kubectl get httproute -A
```

**Note:** The main gateway listens on HTTPS (port 30097) and terminates TLS using the Cloudflare Origin Certificate. HTTPRoutes in any namespace can reference backend Services in other namespaces if a `ReferenceGrant` permits it.

#### 1.5 Install RabbitMQ Cluster Operator (recommended: kubectl)

The repository provides a helper script to install the RabbitMQ Cluster Operator, or you can install it directly from the upstream manifest. We prefer the upstream manifest for a minimal, canonical install:

```bash
kubectl apply -f "https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml"
```

Alternatively run the included installer script which applies the upstream manifest by default and creates the `rabbitmq-system` namespace. The script will abort if it detects a Flux installation (this repository avoids managing Flux-controlled operator deployments). Example:

```powershell
pwsh .\scripts\install-rabbitmq-operator.ps1 -Namespace integration-project-2026-groep-2 -WaitForReady $true
```

If you want the script to also install `cert-manager` (optional), pass `-InstallCertManager $true`:

```powershell
pwsh .\scripts\install-rabbitmq-operator.ps1 -InstallCertManager $true
```

Notes:
- The operator runs in the `rabbitmq-system` namespace and manages `RabbitmqCluster` CRs across namespaces (one operator can serve dev and prod clusters).
- Installing `cert-manager` is optional; without it you must supply TLS secrets yourself or disable auto-TLS in the CR configuration.

#### 1.6 Install ECK

```bash
# Install the CRDs and the operator into its own namespace
kubectl create -f https://download.elastic.co/downloads/eck/2.13.0/crds.yaml
kubectl apply -f https://download.elastic.co/downloads/eck/2.13.0/operator.ya
```

### Step 2: Configure Secrets

Secrets are managed on the destination cluster. Keep the `.env` files local and use them only to bootstrap Kubernetes Secrets into the target namespaces. See [base/secrets/README.md](base/secrets/README.md) for the exact workflow.

#### 2.1 Create your local `.env` files

Copy the `.example` templates to `.env` files and fill in the real values locally.

```powershell
Get-ChildItem base\secrets\*.example | ForEach-Object {
  Copy-Item $_.FullName ($_.FullName -replace '\.example$', '')
}
```

For RabbitMQ, create both `.env.rabbitmq` and `.env.rabbitmq-default-user` from the templates in [base/secrets](base/secrets).

#### 2.2 Bootstrap Kubernetes Secrets on the destination cluster from the local `.env` files

Run [scripts/bootstrap-secrets.ps1](scripts/bootstrap-secrets.ps1) to create or update the required Kubernetes Secrets in your destination cluster namespaces.

**Important:** `.env` files stay out of Git. Argo CD only reads the Kubernetes Secrets that already exist in the destination cluster.

### Step 3: Deploy Platform Workloads via Argo CD

Deploy the Argo CD Applications to sync workloads:

```bash
# Deploy the Argo CD Applications (dev and prod)
kubectl apply -k .
```

This deploys the root Argo CD Applications:
- [argocd/apps/app-dev.yaml](argocd/apps/app-dev.yaml) - Development environment workloads
- [argocd/apps/app-prod.yaml](argocd/apps/app-prod.yaml) - Production environment workloads

Argo CD then automatically syncs all workloads (apps, infrastructure, network policies) from the overlays/dev and overlays/prod Kustomize configurations.

### Step 4: (Optional) Install Headlamp

For cluster visibility and management UI (standalone install, separate namespace):

```bash
# Install Headlamp in its own namespace
kubectl apply -k headlamp

# Port forward to access Headlamp locally:
kubectl port-forward -n headlamp svc/headlamp 3000:80
# Then visit http://localhost:3000
```

## Verification

### 1. Check Gateway Controller and Resources

```bash
# Check NGINX Gateway Fabric controller pod is running
kubectl get pods -n main-gateway -l app.kubernetes.io/name=nginx-gateway-fabric

# Check GatewayClass exists
kubectl get gatewayclass

# Check Gateway and verify it has an address assigned
kubectl get gateway -n main-gateway -o wide

# Check HTTPRoutes are created and accepted
kubectl get httproute -A -o wide
# Look for "Accepted" status in the output
```

### 2. Check Services and ReferenceGrants

```bash
# Verify backend services exist for routing
kubectl get svc -n integration-project-2026-groep-2
kubectl get svc -n integration-project-2026-groep-2-dev
kubectl get svc -n argocd

# Verify ReferenceGrant allows cross-namespace routing
kubectl get referencegrant -A
```

### 3. Test Gateway Connectivity

```bash
# Check if the NodePort service is accessible
kubectl get svc -n main-gateway
# Note the external port for the "ngf-" service

# Port-forward to test the gateway locally (optional)
kubectl port-forward -n main-gateway svc/ngf 8443:443 &
# Then test: curl -k https://localhost:8443 (should return 404 or gateway error, not connection refused)

# Check Argo CD is accessible through the gateway
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Then visit https://localhost:8080
```

### 4. Verify Argo CD Applications

```bash
# Check if applications are syncing
kubectl get applications -A

# Check workload deployments in both environments
kubectl get deployment -n integration-project-2026-groep-2-prod
kubectl get deployment -n integration-project-2026-groep-2-dev
```

## Current Architecture

The shared platform resources live in [base/kustomization.yaml](base/kustomization.yaml). It includes:
- Shared namespace and workloads
- Network policies
- Destination-cluster secret bootstrap flow from local `.env` files

The [gateway/kustomization.yaml](gateway/kustomization.yaml) bundle adds the gateway-specific resources to the `main-gateway` namespace:
- Cluster-scoped `GatewayClass` (nginx)
- Namespaced `Gateway` (main-gateway) on port 30097
- Base HTTPRoute for Argo CD (cross-namespace, with ReferenceGrant in argocd/)

The environment overlays in [overlays/dev/kustomization.yaml](overlays/dev/kustomization.yaml) and [overlays/prod/kustomization.yaml](overlays/prod/kustomization.yaml) add environment-specific HTTPRoutes that route hostnames to backend Services:
- `frontend`, `facturatie`, `kassa`, `mailing`, `planning`, `controlroom`, `crm` in `integration-project-2026-groep-2` (base) namespace
- HTTPRoutes use the same hostnames and targets in both dev and prod, but prefixed for dev (e.g., `dev-kassa.integration-project-2026-groep-2.my.be` → `kassa` service)

The [overlays/dev/kustomization.yaml](overlays/dev/kustomization.yaml) and [overlays/prod/kustomization.yaml](overlays/prod/kustomization.yaml) layers add environment-specific:
- Namespace setup
- Labels and resource tuning

The Argo CD App-of-Apps entry point is [argocd/app-of-apps.yaml](argocd/app-of-apps.yaml), which orchestrates deployment across environments.

## Environments

The overlays are structured for two environments:

- **Development** ([overlays/dev/kustomization.yaml](overlays/dev/kustomization.yaml)): Dev namespace with lighter resource settings
  - Namespace: `integration-project-2026-groep-2-dev`
  - App hosts (dev-prefixed): `dev.integration-project-2026-groep-2.my.be`, etc.

- **Production** ([overlays/prod/kustomization.yaml](overlays/prod/kustomization.yaml)): Prod namespace with higher availability settings
  - Namespace: `integration-project-2026-groep-2-prod`
  - App hosts: `integration-project-2026-groep-2.my.be`, `www.integration-project-2026-groep-2.my.be`, `facturatie.integration-project-2026-groep-2.my.be`, `kassa.integration-project-2026-groep-2.my.be`, `mailing.integration-project-2026-groep-2.my.be`, `rabbitmq.integration-project-2026-groep-2.my.be`

## Secrets Management

Secrets are managed on the destination cluster from local `base/secrets/.env.*` files. Follow these practices:

- **Never commit `.env` files**
- **Keep `.example` files as templates only**
- **Use the bootstrap script** to create Kubernetes Secrets in the destination cluster from your `.env` files
- See [base/secrets/README.md](base/secrets/README.md) for detailed instructions

## Networking

### Single Gateway Entry Point

The platform uses a **single NGINX Gateway** (`main-gateway` in the `main-gateway` namespace) on **NodePort 30097**:

- **External traffic**: Cloudflare routes HTTPS traffic to NodePort 30097
- **TLS termination**: Gateway terminates TLS using the Cloudflare Origin Certificate
- **HTTPRoutes**: Define hostname-to-service routing rules
  - **Same-namespace routes**: Apps in `integration-project-2026-groep-2` (e.g., `frontend`, `kassa`) are routed via HTTPRoutes in the overlay namespaces
  - **Cross-namespace routes**: Argo CD (in `argocd` namespace) is routed via a base HTTPRoute in `gateway/` + a `ReferenceGrant` in `argocd/` to permit the Gateway to reach the service

**Architecture**:
```
Cloudflare (HTTPS) → NodePort 30097 → main-gateway (main-gateway NS) → HTTPRoutes → Backend Services
```

### Gateway API Resources

The gateway API objects are installed in two steps:

1. **Base gateway resources** (from `kubectl apply -k gateway/`):
   - `GatewayClass` (nginx) — Controller reference
   - `Gateway` (main-gateway/main-gateway) — HTTPS listener on port 30097
   - `HTTPRoute` (argocd-route) — Routes `argocd.integration-project-2026-groep-2.my.be` to `argocd-server` (cross-namespace, requires ReferenceGrant)

2. **Environment-specific HTTPRoutes** (from `kubectl apply -k overlays/prod/` or `overlays/dev/`):
   - Routes for `frontend`, `facturatie`, `kassa`, `mailing`, `planning`, `controlroom`, `crm`
   - Dev routes are prefixed (e.g., `dev-kassa.integration-project-2026-groep-2.my.be`)

### Headlamp UI

Headlamp is installed separately in the `headlamp` namespace:
- Routed via HTTPRoute `headlamp-route` on hostname `k8s.integration-project-2026-groep-2.my.be`
- Install with: `kubectl apply -k headlamp`

## Troubleshooting

### Check component status

```bash
# All core components
kubectl get pods --all-namespaces

# Gateway Fabric controller
kubectl get pods -n main-gateway

# Gateway API resources
kubectl get gatewayclass,gateway -n main-gateway
kubectl get httproute -A

# ReferenceGrants for cross-namespace routing
kubectl get referencegrant -A

# Argo CD applications
kubectl get applications -A

# Local secret bootstrap status
kubectl get secrets -n integration-project-2026-groep-2
```

### Common issues

**Applications not syncing in Argo CD**
- Check if the Application is enabled (should appear in ArgoCD UI)
- Verify the Kubernetes Secrets were bootstrapped in the destination cluster from the local `.env` files
- Check logs: `kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server`

**Gateway not routing traffic**
- Verify HTTPRoutes are created and **Accepted**: `kubectl describe httproute -A` (look for `Accepted: true`)
- Verify Gateway has an address assigned: `kubectl describe gateway -n main-gateway` (look for `Status.Addresses`)
- Check if HTTPRoute targets a service that exists: `kubectl get svc -n integration-project-2026-groep-2`
- For cross-namespace routes (e.g., Argo CD), verify the ReferenceGrant exists: `kubectl get referencegrant -A`
- Check what error the HTTPRoute is reporting: `kubectl describe httproute <name> -n <namespace>`
- Check gateway controller logs: `kubectl logs -n main-gateway -l app.kubernetes.io/name=nginx-gateway-fabric`
- Verify NodePort 30097 is open on the node and Cloudflare forwards traffic to it
- Test connectivity to the gateway: `kubectl port-forward -n main-gateway svc/ngf 8443:443` then `curl -k https://localhost:8443`

**Secrets not being injected into pods**
- Verify `.env` files exist in `base/secrets/` locally
- Re-run [scripts/bootstrap-secrets.ps1](scripts/bootstrap-secrets.ps1)
- Check if secrets exist in the destination namespace: `kubectl get secrets -n integration-project-2026-groep-2`

## Notes

The repository reflects a migration from Docker Compose to Kubernetes. The deployment now runs through Argo CD, Kustomize overlays, and destination-cluster Secrets bootstrapped from local `.env` files. Headlamp is installed separately in its own namespace.
