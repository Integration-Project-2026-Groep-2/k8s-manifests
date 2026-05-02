#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deploy RabbitMQ Cluster Operator to Kubernetes cluster
.DESCRIPTION
    This script installs the RabbitMQ Cluster Operator and deploys a RabbitmqCluster instance.
    It assumes you have kubectl configured and FluxCD installed.
.EXAMPLE
    .\install-rabbitmq-operator.ps1
#>

param(
    [string]$KubeContext = "docker-desktop",
    [string]$Namespace = "integration-project-2026-groep-2",
    [int]$Replicas = 3,
    [bool]$WaitForReady = $true,
    [int]$TimeoutSeconds = 600
)

function Write-Status {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ✓ $Message" -ForegroundColor Green
}

function Write-Error {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ✗ $Message" -ForegroundColor Red
}

# Check prerequisites
Write-Status "Checking prerequisites..."

# Check kubectl
try {
    $kubeVersion = kubectl version --client --short
    Write-Success "kubectl found: $kubeVersion"
} catch {
    Write-Error "kubectl not found. Please install kubectl."
    exit 1
}

# Check cluster connection
try {
    kubectl cluster-info | Out-Null
    Write-Success "Connected to cluster: $KubeContext"
} catch {
    Write-Error "Cannot connect to cluster. Please configure kubectl."
    exit 1
}

# Check for Flux
Write-Status "Checking for FluxCD..."
$fluxCheck = kubectl get ns flux-system 2>$null
if (-not $fluxCheck) {
    Write-Status "FluxCD not detected. Operator will be deployed via kubectl apply."
}

# Step 1: Install cert-manager if needed
Write-Status "Checking for cert-manager..."
$certManagerNs = kubectl get ns cert-manager 2>$null
if (-not $certManagerNs) {
    Write-Status "Installing cert-manager..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.yaml
    
    Write-Status "Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager -n cert-manager 2>$null
    Write-Success "cert-manager installed and ready"
} else {
    Write-Success "cert-manager already installed"
}

# Step 2: Create rabbitmq-system namespace
Write-Status "Creating rabbitmq-system namespace..."
kubectl create namespace rabbitmq-system --dry-run=client -o yaml | kubectl apply -f -
Write-Success "Namespace ready"

# Step 3: Install the operator via Helm chart directly
Write-Status "Installing RabbitMQ Cluster Operator..."
try {
    # Add Bitnami Helm repo
    helm repo add bitnami https://charts.bitnami.com/bitnami 2>$null
    helm repo update 2>$null
    
    # Install operator via Helm
    helm upgrade --install rabbitmq-cluster-operator bitnami/rabbitmq-cluster-operator `
        -n rabbitmq-system `
        --set useCertManager=true `
        --set certManager.enabled=true `
        --set operator.image.tag=1.13.1 `
        --wait `
        --timeout 5m
    
    Write-Success "RabbitMQ Cluster Operator installed"
} catch {
    Write-Error "Failed to install operator via Helm. Attempting kubectl apply..."
    # Fallback: Apply operator manifests directly
    kubectl apply -f base/infrastructure/rabbitmq-operator/helm-release.yaml
}

# Step 4: Wait for operator to be ready
if ($WaitForReady) {
    Write-Status "Waiting for operator to be ready (timeout: ${TimeoutSeconds}s)..."
    try {
        kubectl wait --for=condition=available --timeout=${TimeoutSeconds}s `
            deployment/rabbitmq-cluster-operator -n rabbitmq-system
        Write-Success "Operator is ready"
    } catch {
        Write-Error "Operator did not become ready within timeout"
    }
}

# Step 5: Deploy RabbitmqCluster
Write-Status "Deploying RabbitmqCluster to namespace: $Namespace..."

# Create default user secret if it doesn't exist
$secretExists = kubectl get secret rabbitmq-default-user -n $Namespace 2>$null
if (-not $secretExists) {
    Write-Status "Creating default user secret..."
    $username = "guest"
    $password = "guest"  # CHANGE THIS IN PRODUCTION
    
    kubectl create secret generic rabbitmq-default-user `
        --from-literal=username=$username `
        --from-literal=password=$password `
        -n $Namespace `
        --dry-run=client -o yaml | kubectl apply -f -
    
    Write-Status "Default user secret created (username: $username)"
}

# Apply the cluster resources
kubectl apply -k base/infrastructure/rabbitmq/

Write-Success "RabbitmqCluster manifest applied"

# Step 6: Wait for RabbitmqCluster to be ready
if ($WaitForReady) {
    Write-Status "Waiting for RabbitmqCluster to be ready (timeout: ${TimeoutSeconds}s)..."
    try {
        kubectl wait --for=condition=ClusterAvailable --timeout=${TimeoutSeconds}s `
            rabbitmqcluster/rabbitmq -n $Namespace
        Write-Success "RabbitmqCluster is ready"
    } catch {
        Write-Status "Warning: RabbitmqCluster availability check timed out. Checking pods..."
        kubectl get pods -n $Namespace -l app.kubernetes.io/name=rabbitmq
    }
}

# Step 7: Display connection info
Write-Status "`nDeployment Summary:"
Write-Status "==================="
Write-Success "Operator namespace: rabbitmq-system"
Write-Success "Cluster namespace: $Namespace"
Write-Success "Cluster name: rabbitmq"

Write-Status "`nConnection endpoints:"
Write-Status "AMQP (port 5672): rabbitmq.$Namespace.svc.cluster.local:5672"
Write-Status "Management UI (port 15672): rabbitmq.$Namespace.svc.cluster.local:15672"

Write-Status "`nUseful commands:"
Write-Status "================`n"
Write-Host "# Port forward to management UI"
Write-Host "kubectl port-forward svc/rabbitmq 15672:15672 -n $Namespace`n" -ForegroundColor Yellow

Write-Host "# Check cluster status"
Write-Host "kubectl exec rabbitmq-0 -n $Namespace -- rabbitmqctl cluster_status`n" -ForegroundColor Yellow

Write-Host "# View logs"
Write-Host "kubectl logs -f statefulset/rabbitmq -n $Namespace`n" -ForegroundColor Yellow

Write-Host "# Get cluster info"
Write-Host "kubectl get rabbitmqclusters -n $Namespace`n" -ForegroundColor Yellow

Write-Host "# Describe cluster"
Write-Host "kubectl describe rabbitmqcluster rabbitmq -n $Namespace`n" -ForegroundColor Yellow

Write-Status "Installation complete!"
