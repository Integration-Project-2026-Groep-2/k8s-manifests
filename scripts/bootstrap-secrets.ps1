param(
    [string[]]$Namespaces = @(
        'integration-project-2026-groep-2',
        'integration-project-2026-groep-2-dev',
        'integration-project-2026-groep-2-prod'
    )
)

$projectRoot = Split-Path -Parent $PSScriptRoot
$secretFiles = @(
    @{ Name = 'billing-secret'; File = 'base/secrets/.env.billing' },
    @{ Name = 'controlroom-secret'; File = 'base/secrets/.env.controlroom' },
    @{ Name = 'crm-secret'; File = 'base/secrets/.env.crm' },
    @{ Name = 'elasticsearch-secret'; File = 'base/secrets/.env.elasticsearch' },
    @{ Name = 'frontend-secret'; File = 'base/secrets/.env.frontend' },
    @{ Name = 'ingress-basic-auth-secrets'; File = 'base/secrets/.env.ingress' },
    @{ Name = 'kassa-secret'; File = 'base/secrets/.env.kassa' },
    @{ Name = 'mailing-secret'; File = 'base/secrets/.env.mailing' },
    @{ Name = 'planning-secret'; File = 'base/secrets/.env.planning' },
    @{ Name = 'rabbitmq-secret'; File = 'base/secrets/.env.rabbitmq' }
)

foreach ($namespace in $Namespaces) {
    Write-Host "Creating secrets in namespace: $namespace"

    foreach ($secret in $secretFiles) {
        $envPath = Join-Path $projectRoot $secret.File

        if (-not (Test-Path $envPath)) {
            throw "Missing env file: $envPath"
        }

        kubectl create secret generic $secret.Name `
            --from-env-file=$envPath `
            --namespace $namespace `
            --dry-run=client `
            -o yaml |
            kubectl apply -f -
    }
}