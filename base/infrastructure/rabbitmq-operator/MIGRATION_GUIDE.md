# RabbitMQ Cluster Kubernetes Operator Migration Guide

## Overview
This guide explains how to migrate from a manual RabbitMQ Deployment to the **RabbitMQ Cluster Kubernetes Operator**.

### Benefits of the Operator
- **Automatic clustering** - Handles peer discovery and cluster formation
- **High availability** - Built-in support for multiple replicas with anti-affinity rules
- **Declarative management** - Define RabbitMQ clusters as Kubernetes Custom Resources (CRDs)
- **Operator lifecycle** - Automatic scaling, upgrades, and recovery
- **Resource optimization** - Better resource management and health checks

## Architecture

### New Structure
```
base/infrastructure/
├── rabbitmq-operator/          # New: Operator installation
│   ├── namespace.yaml          # Creates rabbitmq-system namespace
│   ├── helm-release.yaml       # HelmRelease for the operator (via Flux)
│   └── kustomization.yaml
│
└── rabbitmq/                   # Updated: Application cluster
    ├── rabbitmq-cluster.yaml   # RabbitmqCluster CRD (replaces Deployment)
    ├── kustomization.yaml
    └── ... (other resources)
```

## Installation Steps

### Step 1: Prerequisites
Ensure you have:
- Kubernetes 1.20+ cluster
- Helm 3.x (if using Helm installation)
- cert-manager 1.0+ (required by the operator)

### Step 2: Install Cert-Manager (if not already installed)
```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.yaml
```

### Step 3: Deploy the Operator
The operator is deployed via Helm using FluxCD. Apply your kustomization:

```bash
kubectl apply -k base/infrastructure/rabbitmq-operator/
```

Wait for the operator deployment to be ready:
```bash
kubectl wait --for=condition=available --timeout=300s deployment/rabbitmq-cluster-operator -n rabbitmq-system
```

### Step 4: Deploy RabbitMQ Cluster
Deploy the RabbitmqCluster custom resource:

```bash
kubectl apply -k base/infrastructure/rabbitmq/
```

Wait for the StatefulSet to be ready:
```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=rabbitmq -n integration-project-2026-groep-2 --timeout=600s
```

## Configuration Reference

### RabbitmqCluster Spec

#### Key Parameters
```yaml
spec:
  replicas: 3                    # Number of nodes in the cluster
  image: rabbitmq:4-management-alpine
  
  persistence:
    storage: 5Gi                 # Storage size for each node
    storageClassName: ""         # Use default storage class
  
  resources:
    requests:
      cpu: 250m
      memory: 256Mi
    limits:
      cpu: 1000m
      memory: 512Mi
  
  service:
    type: ClusterIP              # Can also be LoadBalancer or NodePort
  
  rabbitmq:
    additionalConfig: |
      # Custom RabbitMQ configuration
      management.tcp.port = 15672
```

## Migration Path

### From Old Setup to Operator

1. **Backup current data** (if upgrading from existing RabbitMQ)
   ```bash
   kubectl exec -it rabbitmq-0 -n integration-project-2026-groep-2 -- \
     rabbitmqctl export_definitions /tmp/definitions.json
   ```

2. **Scale down old deployment**
   ```bash
   kubectl scale deployment rabbitmq --replicas=0 -n integration-project-2026-groep-2
   ```

3. **Deploy operator and cluster**
   - Apply the operator and RabbitmqCluster resources
   - Verify all pods are running

4. **Restore definitions** (if migrating data)
   ```bash
   kubectl cp /tmp/definitions.json rabbitmq-0:/tmp/ -n integration-project-2026-groep-2
   kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- \
     rabbitmqctl import_definitions /tmp/definitions.json
   ```

5. **Delete old resources**
   ```bash
   kubectl delete deployment rabbitmq -n integration-project-2026-groep-2
   kubectl delete pvc rabbitmq-data rabbitmq-logs -n integration-project-2026-groep-2
   ```

## Secret Management

### Default User Configuration
The default user credentials are stored in the `rabbitmq-default-user` secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: rabbitmq-default-user
  namespace: integration-project-2026-groep-2
data:
  username: <base64-encoded-username>
  password: <base64-encoded-password>
```

To update credentials:
```bash
kubectl create secret generic rabbitmq-default-user \
  --from-literal=username=myuser \
  --from-literal=password=mypassword \
  -n integration-project-2026-groep-2 \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Monitoring & Management

### Access Management UI
```bash
kubectl port-forward svc/rabbitmq 15672:15672 -n integration-project-2026-groep-2
# Open http://localhost:15672
```

### Check Cluster Status
```bash
kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- rabbitmq-diagnostics -q check_running
kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- rabbitmqctl cluster_status
```

### View Logs
```bash
kubectl logs -f statefulset/rabbitmq -n integration-project-2026-groep-2
```

### Get Cluster Info
```bash
kubectl get rabbitmqclusters -n integration-project-2026-groep-2
kubectl describe rabbitmqcluster rabbitmq -n integration-project-2026-groep-2
```

## Troubleshooting

### Operator not starting
```bash
kubectl logs -f deployment/rabbitmq-cluster-operator -n rabbitmq-system
```

### Cluster stuck in pending
Check resource availability:
```bash
kubectl describe rabbitmqcluster rabbitmq -n integration-project-2026-groep-2
kubectl top nodes
```

### Pod not starting
```bash
kubectl describe pod rabbitmq-0 -n integration-project-2026-groep-2
```

## Advanced Configuration

### Enable Plugins
```yaml
rabbitmq:
  additionalConfig: |
    management.load_definitions = /etc/rabbitmq/definitions.json
```

### Custom Environment Variables
Update the `override` section in `rabbitmq-cluster.yaml`:
```yaml
override:
  kind: StatefulSet
  spec:
    template:
      spec:
        containers:
        - name: rabbitmq
          env:
          - name: CUSTOM_VAR
            value: custom_value
```

### Multiple Namespaces
Deploy multiple RabbitmqCluster resources in different namespaces as needed.

## Rollback Procedure

If you need to roll back to the manual deployment:

1. Keep a backup of the old deployment YAML
2. Delete the RabbitmqCluster and operator:
   ```bash
   kubectl delete rabbitmqcluster rabbitmq -n integration-project-2026-groep-2
   kubectl delete helmrelease rabbitmq-cluster-operator -n rabbitmq-system
   ```
3. Reapply the old deployment from backup
4. Restore data if needed

## References

- [RabbitMQ Cluster Operator Documentation](https://www.rabbitmq.com/kubernetes/operator/operator-overview)
- [RabbitmqCluster CRD Reference](https://github.com/rabbitmq/cluster-operator/blob/main/docs/README-CRD.md)
- [Best Practices](https://www.rabbitmq.com/kubernetes/operator/using-operator)

