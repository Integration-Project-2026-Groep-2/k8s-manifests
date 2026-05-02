# RabbitMQ Operator Implementation - Quick Reference

## What Was Changed

### New Files Created
```
base/infrastructure/rabbitmq-operator/
├── namespace.yaml              # Creates rabbitmq-system namespace
├── helm-release.yaml           # HelmRelease for operator deployment
├── operator-values.yaml        # Helm values configuration
├── kustomization.yaml          # Kustomize orchestration
└── MIGRATION_GUIDE.md          # Detailed migration instructions

base/infrastructure/kustomization.yaml  # Updated to include operator
base/infrastructure/rabbitmq/
├── README.md                   # Quick reference and troubleshooting
├── rabbitmq-cluster.yaml       # RabbitmqCluster CRD (replaces deployment)
└── kustomization.yaml          # Updated for operator setup

scripts/install-rabbitmq-operator.ps1   # Automated installation script
```

### Files Modified
- `base/kustomization.yaml` - Updated to use new infrastructure structure
- `base/infrastructure/rabbitmq/kustomization.yaml` - Changed from deployment-based to CRD-based

## Key Improvements

### High Availability
- **Before**: 1 single-node deployment
- **After**: 3-node cluster with automatic clustering and failover

### Operator Features
- ✅ Automatic peer discovery and cluster formation
- ✅ Automatic pod restart on failure
- ✅ Automatic scaling of cluster
- ✅ Operator-managed resource lifecycle
- ✅ Better health checks and monitoring

### Persistence & Storage
- Dedicated PersistentVolumeClaims per node
- Configurable storage size and class

## Quick Start Commands

### 1. Install Operator and RabbitMQ
```bash
# Automated (recommended)
pwsh ./scripts/install-rabbitmq-operator.ps1

# Or manually
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.yaml
kubectl apply -k base/infrastructure/rabbitmq-operator/
kubectl apply -k base/infrastructure/rabbitmq/
```

### 2. Verify Installation
```bash
kubectl get pods -n rabbitmq-system
kubectl get pods -n integration-project-2026-groep-2 -l app.kubernetes.io/name=rabbitmq
```

### 3. Access Management UI
```bash
kubectl port-forward svc/rabbitmq 15672:15672 -n integration-project-2026-groep-2
# Open http://localhost:15672 (username: guest, password: guest)
```

### 4. Check Cluster Status
```bash
kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- rabbitmqctl cluster_status
```

## Configuration Options

| Feature | Location | How to Change |
|---------|----------|--------------|
| Cluster size (replicas) | `rabbitmq-cluster.yaml` line 40 | Change `replicas: 3` to desired number |
| Storage size | `rabbitmq-cluster.yaml` line 51 | Change `storage: 5Gi` |
| CPU/Memory limits | `rabbitmq-cluster.yaml` lines 47-49 | Modify resource requests/limits |
| Image version | `rabbitmq-cluster.yaml` line 37 | Change image tag |
| Default password | Secret `rabbitmq-default-user` | Update secret before deployment |

## Connecting Applications

### From Within Cluster
```
amqp://guest:guest@rabbitmq.integration-project-2026-groep-2.svc.cluster.local:5672
```

### Environment Variables
Applications should use:
```bash
RABBITMQ_HOST=rabbitmq.integration-project-2026-groep-2.svc.cluster.local
RABBITMQ_PORT=5672
RABBITMQ_USER=guest
RABBITMQ_PASS=guest
RABBITMQ_VHOST=/
```

## Useful Commands

```bash
# View cluster info
kubectl get rabbitmqclusters -n integration-project-2026-groep-2
kubectl describe rabbitmqcluster rabbitmq -n integration-project-2026-groep-2

# Monitor logs
kubectl logs -f statefulset/rabbitmq -n integration-project-2026-groep-2

# Shell access
kubectl exec -it rabbitmq-0 -n integration-project-2026-groep-2 -- bash

# Cluster diagnostics
kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- rabbitmq-diagnostics report

# List users
kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- rabbitmqctl list_users

# List vhosts
kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- rabbitmqctl list_vhosts

# List queues
kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- rabbitmqctl list_queues
```

## Scaling

```bash
# Scale to 5 nodes
kubectl patch rabbitmqcluster rabbitmq -n integration-project-2026-groep-2 \
  -p '{"spec":{"replicas":5}}' --type merge

# Scale back to 3 nodes
kubectl patch rabbitmqcluster rabbitmq -n integration-project-2026-groep-2 \
  -p '{"spec":{"replicas":3}}' --type merge
```

## Important Notes

1. **First deployment takes time**: The operator needs to create the cluster from scratch. Be patient (5-10 minutes).

2. **Persistent storage required**: Ensure your cluster has a default StorageClass or specify one in `rabbitmq-cluster.yaml`.

3. **cert-manager dependency**: The operator requires cert-manager. It will be installed automatically by the script.

4. **Password management**: Change the default "guest" password immediately for production environments.

5. **Backup data**: Export definitions before major changes:
   ```bash
   kubectl exec rabbitmq-0 -n integration-project-2026-groep-2 -- \
     rabbitmqctl export_definitions /tmp/definitions.json
   ```

## Troubleshooting

### Pods won't start
```bash
# Check events
kubectl describe pod rabbitmq-0 -n integration-project-2026-groep-2

# Check operator logs
kubectl logs -f deployment/rabbitmq-cluster-operator -n rabbitmq-system

# Check events on the cluster resource
kubectl describe rabbitmqcluster rabbitmq -n integration-project-2026-groep-2
```

### Can't connect to RabbitMQ
```bash
# Verify pod is running
kubectl get pods -n integration-project-2026-groep-2 -l app.kubernetes.io/name=rabbitmq

# Check if service exists
kubectl get svc -n integration-project-2026-groep-2 | grep rabbitmq

# Test connection from pod
kubectl run -it --image=alpine --restart=Never rabbitmq-test -- sh
# apk add busybox-extras
# telnet rabbitmq 5672
```

### Memory or disk issues
```bash
# Check PVC status
kubectl get pvc -n integration-project-2026-groep-2 -l app.kubernetes.io/name=rabbitmq

# Check node resources
kubectl top nodes
kubectl top pods -n integration-project-2026-groep-2

# Describe a failing PVC
kubectl describe pvc <pvc-name> -n integration-project-2026-groep-2
```

## Migration from Old Deployment

If you have an existing RabbitMQ deployment, see `MIGRATION_GUIDE.md` for step-by-step migration instructions.

## Further Reading

- [RabbitMQ Operator Documentation](https://www.rabbitmq.com/kubernetes/operator/operator-overview)
- [RabbitmqCluster API Reference](https://github.com/rabbitmq/cluster-operator/blob/main/docs/README-CRD.md)
