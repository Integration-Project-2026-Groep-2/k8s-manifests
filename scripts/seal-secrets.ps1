<#
Seals all env files in `base/secrets` into SealedSecret manifests in `base/secrets`.
Requires: kubectl, kubeseal (https://github.com/bitnami-labs/sealed-secrets)
Usage: .\scripts\seal-secrets.ps1 [-Namespace <k8s namespace>]
Always fetches the controller cert and strips namespace fields so Kustomize can set them.
#>
param(
    [string]$Namespace = "integration-project-2026-groep-2"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $FilePath $($Arguments -join ' ')"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$secretsDir = Join-Path $repoRoot "base\secrets"
$sealedDir = Join-Path $repoRoot "base\secrets"

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Error "kubectl not found in PATH"
    exit 2
}
if (-not (Get-Command kubeseal -ErrorAction SilentlyContinue)) {
    Write-Error "kubeseal not found in PATH"
    exit 2
}

if (-not (Test-Path $sealedDir)) {
    New-Item -ItemType Directory -Path $sealedDir | Out-Null
}

Write-Output "Fetching Sealed Secrets controller cert from cluster..."
$certPath = Join-Path $sealedDir "pub-cert.pem"
Invoke-Checked -FilePath kubeseal -Arguments @(
    '--controller-name=sealed-secrets',
    '--controller-namespace=kube-system',
    '--fetch-cert'
) | Set-Content -Path $certPath -Encoding ascii

$useCert = $false
try {
    $null = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certPath
    $useCert = $true
} catch {
    Write-Warning "Cert file '$certPath' is not a valid X509 certificate. Falling back to controller RPC."
    $useCert = $false
}

$envFiles = Get-ChildItem -Path $secretsDir -File |
    Where-Object { $_.Name -like '.env.*' -and $_.Name -notlike '*.example' }

if (-not $envFiles) {
    Write-Warning "No .env files found in $secretsDir"
    exit 0
}

foreach ($env in $envFiles) {
    $envFile = $env.FullName

    # filename like .env.billing -> name billing
    $fileName = $env.Name
    if ($fileName -like '.env.*') {
        $name = $fileName.Substring(5)
    } else {
        $name = $env.BaseName
    }
    if ([string]::IsNullOrEmpty($name)) {
        $name = $env.BaseName.TrimStart('.')
    }

    $secretName = "${name}-secret"
    $outFile = Join-Path $sealedDir ("${name}-sealedsecret.yaml")
    $tempFile = Join-Path $sealedDir ("temp-${name}-secret.yaml")
    $sealedTemp = Join-Path $sealedDir ("temp-${name}-sealedsecret.yaml")

    Write-Output "Sealing '$envFile' as '$secretName' -> $outFile"

    try {
        $kubectlArgs = @(
            'create','secret','generic',$secretName,
            "--from-env-file=$envFile",
            "--namespace=$Namespace",
            '--dry-run=client','-o','yaml'
        )
        Invoke-Checked -FilePath kubectl -Arguments $kubectlArgs | Set-Content -Path $tempFile -Encoding utf8

        $sealArgs = @('--format','yaml','--scope','cluster-wide')
        if ($useCert) {
            $sealArgs += @('--cert',$certPath)
        }

        Get-Content -Path $tempFile -Raw | & kubeseal @sealArgs | Set-Content -Path $sealedTemp -Encoding utf8
        if ($LASTEXITCODE -ne 0) {
            throw "kubeseal failed for $envFile"
        }

        # Remove explicit namespace lines so kustomize can inject dev/prod namespaces
        Get-Content -Path $sealedTemp | Where-Object { $_ -notmatch '^\s*namespace:\s*' } |
            Set-Content -Path $outFile -Encoding utf8

        Write-Output "Wrote $outFile"
    } catch {
        Write-Error "Failed sealing ${envFile}: $($_)"
    } finally {
        Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
        Remove-Item -Path $sealedTemp -ErrorAction SilentlyContinue
    }
}

Write-Output "Done. Review files in base/secrets and commit them."