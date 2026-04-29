> [!CAUTION]
> This is still a Work In Progress, it will probably NOT WORK

# Kubernetes Manifests

This repository contains the Kubernetes manifests for the integration platform.
It is set up for GitOps with Argo CD and uses Kustomize overlays for dev and prod.

## What is here

```text
.
├── argocd/              Argo CD App-of-Apps and child Applications
├── apps/                Team services and their deployments
├── gateway/             NGINX Gateway Fabric and Gateway API config
├── infrastructure/      Elasticsearch, Kibana, RabbitMQ
├── network-policies/    Default deny and workload network rules
├── overlays/            dev and prod Kustomize overlays
└── secrets/             SealedSecrets manifests
```

## Current setup

The root [kustomization.yaml](kustomization.yaml) includes the shared namespace, all workloads, gateway config, network policies, and the committed SealedSecrets resources. Plaintext Secret manifests are no longer part of the bootstrap path.

The Argo CD App-of-Apps entry point is [argocd/app-of-apps.yaml](argocd/app-of-apps.yaml). It points at [argocd/apps](argocd/apps), where the dev and prod Applications live:

- [argocd/apps/app-dev.yaml](argocd/apps/app-dev.yaml)
- [argocd/apps/app-prod.yaml](argocd/apps/app-prod.yaml)

## Prerequisites

1. Install Gateway API CRDs.
2. Install NGINX Gateway Fabric using [gateway/gateway-controller-values.yaml](gateway/gateway-controller-values.yaml).
3. Install Argo CD.
4. Install the Sealed Secrets controller.
5. Optionally install Headlamp for cluster visibility.

Example commands:

```bash
kubectl kustomize "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=v2.5.1" | kubectl apply -f -

helm install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  -n nginx-gateway --create-namespace \
  -f gateway/gateway-controller-values.yaml

kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system
```

## Deployment

Bootstrap the repository in two steps:

```bash
# 1. Deploy the platform workloads
kubectl apply -k .

# 2. Bootstrap Argo CD's app-of-apps entry point
kubectl apply -k argocd/
```

The root Kustomize entry point creates the workloads, secrets, gateway, and network policies. The separate [argocd/kustomization.yaml](argocd/kustomization.yaml) creates the `app-of-apps` Application, which then registers:

- [argocd/apps/app-dev.yaml](argocd/apps/app-dev.yaml)
- [argocd/apps/app-prod.yaml](argocd/apps/app-prod.yaml)

Argo CD then syncs the dev or prod overlay depending on which Application you enable.

## Environments

The overlays are:

- [overlays/dev/kustomization.yaml](overlays/dev/kustomization.yaml) for the development namespace and lighter resource settings.
- [overlays/prod/kustomization.yaml](overlays/prod/kustomization.yaml) for the production namespace and higher availability settings.

## Secrets

Secrets are stored as SealedSecrets under [secrets](secrets). Commit the sealed manifests, not plaintext Secret objects. If you need to rotate a secret, regenerate the SealedSecret and replace the matching file in this directory.

The companion notes are in [secrets/README.md](secrets/README.md).

## Networking

The gateway controller exposes a single NodePort entrypoint for inbound traffic. Current configuration uses port 30097 and trusts Cloudflare proxy headers through the Gateway controller values file.

## Notes

The repository still reflects a migration from Docker Compose, so some comments and manifests are intentionally transitional. The most important current change is that the deployment path now runs through Argo CD, Kustomize overlays, and SealedSecrets instead of local `.env`-driven secret generation.
