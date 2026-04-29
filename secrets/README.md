# Secrets

Secrets are managed locally using Kustomize's `secretGenerator` with `.env` files. **No secrets are committed to Git** — this directory only tracks `.example` template files and configuration.

## What to commit

Commit only `.example` files (templates). Keep all `.env` files local and out of Git.

```
secrets/
├── .env.billing              ← LOCAL ONLY (not committed)
├── .env.billing.example      ← Commit this (template)
├── .env.crm                  ← LOCAL ONLY (not committed)
├── .env.crm.example          ← Commit this (template)
└── ... etc for each service
```

## Setup

1. **Copy example files to create actual secrets:**
   ```powershell
   Copy-Item secrets/.env.*.example -Replace {$_ -replace '.example', ''} -Destination secrets/
   ```

2. **Edit each `.env.SERVICE` file with your actual values:**
   ```powershell
   # Edit with your values
   notepad secrets/.env.billing
   notepad secrets/.env.rabbitmq
   # ... etc for each service
   ```

3. **Verify `.env` files are in `.gitignore`** (they should be automatically):
   ```powershell
   git check-ignore secrets/.env.*
   ```

## Deployment

When you run `kubectl apply -k .`, Kustomize automatically:
- Reads all `.env.SERVICE` files from the secrets directory
- Generates Kubernetes Secrets from them
- Applies them to the cluster

The [root kustomization.yaml](../kustomization.yaml) contains the `secretGenerator` configuration that handles this automatically.

## Adding a new service

1. Create `.env.NEWSERVICE` file with required variables
2. Commit `.env.NEWSERVICE.example` as a template
3. Add to `secretGenerator` in [kustomization.yaml](../kustomization.yaml):
   ```yaml
   secretGenerator:
     - name: newservice-secret
       envs:
         - secrets/.env.newservice
   ```
