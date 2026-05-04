# RabbitMQ with Kubernetes Operator

## Overview
This directory contains the configuration for RabbitMQ deployed using the **RabbitMQ Cluster Kubernetes Operator**.

## Structure
```
rabbitmq/
├── rabbitmq-cluster.yaml    # RabbitmqCluster CRD with operator configuration
├── kustomization.yaml       # Kustomize configuration for the cluster
└── README.md               # This file
```

## Key Features
- **3-node cluster** by default (configurable)
- **Persistent storage** using PersistentVolumeClaims
- **High availability** with pod anti-affinity rules
- **Management UI** accessible on port 15672
- **AMQP** accessible on port 5672
- **Operator-managed lifecycle** - automatic recovery and updates

## Quick Start

### Prerequisites
- Kubernetes 1.20+
- cert-manager 1.0+ (required for the operator)
- Helm 3.x (optional, used by installation script)
- kubectl configured for your cluster

### Installation

#### Option 1: Using the provided script (Recommended)
```bash
pwsh ./scripts/install-rabbitmq-operator.ps1
```

#### Option 2: Manual installation
```bash
# 1. Install cert-manager if not present
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.yaml

# 2. Install the operator
kubectl apply -k base/infrastructure/rabbitmq-operator/

# 3. Deploy the RabbitmqCluster
kubectl apply -k base/infrastructure/rabbitmq/
```

### Verify Installation
```bash
# Check operator is running
kubectl get deployment -n rabbitmq-system
kubectl logs -f deployment/rabbitmq-cluster-operator -n rabbitmq-system

# Check cluster pods
kubectl get pods -n integration-project-2026-groep-2 -l app.kubernetes.io/name=rabbitmq

# Check cluster status
kubectl describe rabbitmqcluster rabbitmq -n integration-project-2026-groep-2
```

## Configuration

### Cluster Size
Edit the `replicas` field in `rabbitmq-cluster.yaml`:
```yaml
spec:
  replicas: 3  # Change to desired number of nodes
```

### Storage
Configure persistent storage:
```yaml
persistence:
  storage: 5Gi                 # Storage size
  storageClassName: ""         # Use default or specify a class
```

### Resource Limits
Adjust CPU and memory:
```yaml
resources:
  requests:
    cpu: 250m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 512Mi
```

### Default User
Update credentials by modifying the `rabbitmq-default-user` secret:
```bash
kubectl delete secret rabbitmq-default-user -n integration-project-2026-groep-2
kubectl create secret generic rabbitmq-default-user \
  --from-literal=username=myuser \
  --from-literal=password=mypassword \
  -n integration-project-2026-groep-2
```

## Access

### Management UI
```bash
kubectl port-forward svc/rabbitmq 15672:15672 -n integration-project-2026-groep-2
# Open http://localhost:15672 in your browser
```

### AMQP Connection (from within cluster)
```
amqp://username:password@rabbitmq.integration-project-2026-groep-2.svc.cluster.local:5672
```

### Command Line Tools
```bash
# SSH into a pod
kubectl exec -it rabbitmq-0 -n integration-project-2026-groep-2 -- bash

# Check cluster status
kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- rabbitmqctl cluster_status

# List users
kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- rabbitmqctl list_users

# List vhosts
kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- rabbitmqctl list_vhosts
```

## Monitoring

### Logs
```bash
# Tail logs from all pods
kubectl logs -f statefulset/rabbitmq -n integration-project-2026-groep-2

# Logs from specific pod
kubectl logs -f rabbitmq-0 -n integration-project-2026-groep-2
```

### Health Checks
```bash
# Ping RabbitMQ
kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- rabbitmq-diagnostics -q ping

# Check running status
kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- rabbitmq-diagnostics -q check_running

# Full diagnostics
kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- rabbitmq-diagnostics report
```

### Resource Usage
```bash
# Check pod resource usage
kubectl top pods -n integration-project-2026-groep-2 -l app.kubernetes.io/name=rabbitmq
```

## Scaling

### Scale Up
```bash
# Increase replicas
kubectl patch rabbitmqcluster rabbitmq -n integration-project-2026-groep-2 \
  -p '{"spec":{"replicas":5}}' --type merge
```

### Scale Down
```bash
# Decrease replicas
kubectl patch rabbitmqcluster rabbitmq -n integration-project-2026-groep-2 \
  -p '{"spec":{"replicas":1}}' --type merge
```

## Backup & Recovery

### Export Definitions
```bash
kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- \
  rabbitmqctl export_definitions /tmp/definitions.json

kubectl cp integration-project-2026-groep-2/rabbitmq-0:/tmp/definitions.json ./definitions.json
```

### Import Definitions
```bash
kubectl cp ./definitions.json integration-project-2026-groep-2/rabbitmq-0:/tmp/

kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- \
  rabbitmqctl import_definitions /tmp/definitions.json
```

## Troubleshooting

### Pods stuck in pending
```bash
# Check pod status
kubectl describe pod rabbitmq-0 -n integration-project-2026-groep-2

# Check resource availability
kubectl top nodes
kubectl describe nodes
```

### High memory usage
Adjust resource requests/limits and review queue lengths:
```bash
kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- \
  rabbitmqctl list_queues name messages
```

### Cluster communication issues
```bash
# Check cluster status
kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- \
  rabbitmqctl cluster_status

# Logs show connection issues
kubectl logs -f rabbitmq-0 -n integration-project-2026-groep-2
```

### Reset cluster (WARNING: Deletes data)
```bash
# Delete the RabbitmqCluster
kubectl delete rabbitmqcluster rabbitmq -n integration-project-2026-groep-2

# Delete PersistentVolumeClaims
kubectl delete pvc -l app.kubernetes.io/name=rabbitmq -n integration-project-2026-groep-2

# Recreate
kubectl apply -k base/infrastructure/rabbitmq/
```

## Migration from Manual Deployment

See [MIGRATION_GUIDE.md](../rabbitmq-operator/MIGRATION_GUIDE.md) for detailed steps to migrate from the previous manual deployment.

## References

- [RabbitMQ Kubernetes Operator](https://www.rabbitmq.com/kubernetes/operator/operator-overview)
- [RabbitmqCluster CRD API](https://github.com/rabbitmq/cluster-operator/blob/main/docs/README-CRD.md)
- [RabbitMQ Best Practices](https://www.rabbitmq.com/kubernetes/operator/using-operator)
- [cert-manager Installation](https://cert-manager.io/docs/installation/)

## Support

For issues with the operator, check:
1. Operator logs: `kubectl logs -f deployment/rabbitmq-cluster-operator -n rabbitmq-system`
2. RabbitMQ logs: `kubectl logs -f statefulset/rabbitmq -n integration-project-2026-groep-2`
3. RabbitmqCluster events: `kubectl describe rabbitmqcluster rabbitmq -n integration-project-2026-groep-2`
