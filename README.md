# Kubernetes Manifests

This repository contains the Kubernetes manifests for the integration platform.
It is set up for GitOps with Argo CD and uses Kustomize overlays for dev and prod environments.

## What is here

```text
.
├── base/               Shared Kustomize base for workloads, gateway class, and policies
├── argocd/              Argo CD App-of-Apps and child Applications
├── apps/                Team services and their deployments
├── gateway/             NGINX Gateway Fabric and Gateway API config
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

### Step 1: Install Core Infrastructure Components

Install the required controllers and admission systems:

#### 1.1 Install Gateway API CRDs

```bash
kubectl kustomize "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=v2.5.1" | kubectl apply -f -
```

#### 1.2 Install NGINX Gateway Fabric

```bash
helm install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  -n nginx-gateway --create-namespace \
  -f gateway/gateway-controller-values.yaml

# Verify it's running
kubectl get pods -n nginx-gateway
```

#### 1.3 Install Argo CD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for Argo CD to be ready
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
```

#### 1.4 Install Sealed Secrets Controller (Helm preferred)

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

### Step 2: Configure Secrets

Secrets are managed on the destination cluster. Keep the `.env` files local and use them only to bootstrap Kubernetes Secrets into the target namespaces. See [base/secrets/README.md](base/secrets/README.md) for the exact workflow.

#### 2.1 Create your local `.env` files

Copy the `.example` templates to `.env` files and fill in the real values locally.

```powershell
Get-ChildItem base\secrets\*.example | ForEach-Object {
  Copy-Item $_.FullName ($_.FullName -replace '\.example$', '')
}
```

#### 2.2 Bootstrap Kubernetes Secrets on the destination cluster from the local `.env` files

Run [scripts/bootstrap-secrets.ps1](scripts/bootstrap-secrets.ps1) to create or update the required Kubernetes Secrets in your destination cluster namespaces.

**Important:** `.env` files stay out of Git. Argo CD only reads the Kubernetes Secrets that already exist in the destination cluster.

### Step 3: Deploy Platform Workloads

Deploy the base platform resources:

```bash
# Deploy base resources (workloads, gateway, network policies, secrets)
kubectl apply -k .
```

This command applies all resources from the base Kustomize configuration, including:
- Namespaces
- Workloads (apps, infrastructure)
- Gateway resources
- Network policies

It does not create the application secrets. Those are created separately on the destination cluster from your local `.env` files.

### Step 4: Bootstrap Argo CD

Initialize Argo CD's App-of-Apps pattern:

```bash
# Bootstrap Argo CD with the app-of-apps entry point
kubectl apply -k argocd/
```

This creates the `app-of-apps` Application which then automatically registers:
- [argocd/apps/app-dev.yaml](argocd/apps/app-dev.yaml) - Development environment
- [argocd/apps/app-prod.yaml](argocd/apps/app-prod.yaml) - Production environment

### Step 5: (Optional) Install Headlamp

For cluster visibility and management UI:

```bash
# Headlamp is automatically deployed as part of the base configuration
# It will be available once port forwarding or ingress is set up

# Port forward to access Headlamp locally:
kubectl port-forward -n integration-project-2026-groep-2-dev svc/headlamp 3000:80
# Then visit http://localhost:3000
```

## Verification

Verify that all components are running correctly:

```bash
# Check Gateway Fabric
kubectl get pods -n nginx-gateway

# Check Argo CD
kubectl get pods -n argocd

# Check application namespaces
kubectl get namespaces -o name | Select-String integration-project

# Check if applications are syncing in Argo CD
kubectl get applications -A

# View Argo CD UI (port forward)
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Then visit https://localhost:8080 (ignore certificate warning)
```

## Current Architecture

The shared platform resources live in [base/kustomization.yaml](base/kustomization.yaml). It includes:
- Shared namespace and workloads
- Gateway class definition
- Headlamp deployment
- Network policies
- Destination-cluster secret bootstrap flow from local `.env` files

The [overlays/dev/kustomization.yaml](overlays/dev/kustomization.yaml) and [overlays/prod/kustomization.yaml](overlays/prod/kustomization.yaml) layers add environment-specific:
- Gateway configurations
- Namespace setup
- Labels and resource tuning

The Argo CD App-of-Apps entry point is [argocd/app-of-apps.yaml](argocd/app-of-apps.yaml), which orchestrates deployment across environments.

## Environments

The overlays are structured for two environments:

- **Development** ([overlays/dev/kustomization.yaml](overlays/dev/kustomization.yaml)): Dev namespace with lighter resource settings
  - Namespace: `integration-project-2026-groep-2-dev`
  - Headlamp: `dev-headlamp.integration-project-2026-groep-2.my.be`
  - App hosts (dev-prefixed): `dev.integration-project-2026-groep-2.my.be`, etc.

- **Production** ([overlays/prod/kustomization.yaml](overlays/prod/kustomization.yaml)): Prod namespace with higher availability settings
  - Namespace: `integration-project-2026-groep-2-prod`
  - Headlamp: `headlamp.integration-project-2026-groep-2.my.be`
  - App hosts: `integration-project-2026-groep-2.my.be`, `www.integration-project-2026-groep-2.my.be`, `facturatie.integration-project-2026-groep-2.my.be`, `kassa.integration-project-2026-groep-2.my.be`, `mailing.integration-project-2026-groep-2.my.be`, `rabbitmq.integration-project-2026-groep-2.my.be`

## Secrets Management

Secrets are managed on the destination cluster from local `base/secrets/.env.*` files. Follow these practices:

- **Never commit `.env` files**
- **Keep `.example` files as templates only**
- **Use the bootstrap script** to create Kubernetes Secrets in the destination cluster from your `.env` files
- See [base/secrets/README.md](base/secrets/README.md) for detailed instructions

## Networking

The gateway controller exposes the platform on **NodePort 30097**:

- **Cloudflare**: Routes inbound web traffic to port 30097
- **Kubernetes Gateway**: Terminates TLS using the Cloudflare Origin Certificate
- **Architecture**: Cloudflare (HTTPS) → K8s Gateway on port 30097 (HTTPS with origin cert) → Apps
- **Headlamp**: Deployed per environment and routed through the same gateway layer

## Troubleshooting

### Check component status

```bash
# All core components
kubectl get pods --all-namespaces

# Gateway Fabric status
kubectl get gatewayclass,gateway,httproute

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
- Verify HTTPRoutes are created: `kubectl get httproutes -A`
- Check gateway controller logs: `kubectl logs -n nginx-gateway -l app=nginx-gateway`
- Ensure NodePort 30097 is accessible

**Secrets not being injected into pods**
- Verify `.env` files exist in `base/secrets/` locally
- Re-run [scripts/bootstrap-secrets.ps1](scripts/bootstrap-secrets.ps1)
- Check if secrets exist in the destination namespace: `kubectl get secrets -n integration-project-2026-groep-2`

## Notes

The repository reflects a migration from Docker Compose to Kubernetes. The deployment now runs through Argo CD, Kustomize overlays, and destination-cluster Secrets bootstrapped from local `.env` files. All components are designed to work together in this GitOps workflow.
