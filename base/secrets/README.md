# Secrets

Secrets are managed on the destination cluster. The repository keeps `.example` templates, while the real `.env` files stay local and are only used to bootstrap Kubernetes Secrets into the target cluster.

## What to commit

Commit the `.example` files as templates. Keep the `.env` files local and out of Git.

```
secrets/
├── .env.billing              ← LOCAL ONLY (not committed)
├── .env.billing.example      ← Commit this (template)
├── .env.crm                  ← LOCAL ONLY (not committed)
├── .env.crm.example          ← Commit this (template)
├── .env.rabbitmq             ← LOCAL ONLY (not committed)
├── .env.rabbitmq.example     ← Commit this (template)
├── .env.rabbitmq-default-user ← LOCAL ONLY (not committed)
├── .env.rabbitmq-default-user.example
│                             ← Commit this (template)
└── ... etc for each service
```

## Setup

1. **Copy example files to create local `.env` files:**
   ```powershell
   Get-ChildItem base\secrets\*.example | ForEach-Object {
       Copy-Item $_.FullName ($_.FullName -replace '\.example$', '')
   }
   ```

2. **Edit each `.env.SERVICE` file with your actual values:**
   ```powershell
   # Edit with your values
   notepad base\secrets\.env.billing
   notepad base\secrets\.env.rabbitmq
   notepad base\secrets\.env.rabbitmq-default-user
   # ... etc for each service
   ```

3. **Verify the `.env` files are ignored by Git**:
   ```powershell
   git check-ignore base/secrets/.env.*
   ```

## Deployment

Use the local `.env` files to create Kubernetes Secrets on the destination cluster before syncing Argo CD. The helper script at [scripts/bootstrap-secrets.ps1](../../scripts/bootstrap-secrets.ps1) creates the Secrets in the target namespaces.

If you prefer manual commands, create each Secret with `kubectl create secret generic ... --from-env-file=...` and apply it directly to the destination namespace.

## Adding a new service

1. Create `.env.NEWSERVICE` file with required variables
2. Commit `.env.NEWSERVICE.example` as a template
3. Update your local bootstrap script or manual secret creation step to include the new Secret name and `.env` file

### RabbitMQ

RabbitMQ uses two secrets:

* `.env.rabbitmq` -> `rabbitmq-secret` for `RABBITMQ_USER`, `RABBITMQ_PASS`, `RABBITMQ_VHOST`, and `RABBITMQ_MANAGEMENT_PREFIX`
* `.env.rabbitmq-default-user` -> `rabbitmq-default-user` for `username` and `password`

Seal both files with `scripts/seal-secrets.ps1` and commit the generated `*-sealedsecret.yaml` files.
