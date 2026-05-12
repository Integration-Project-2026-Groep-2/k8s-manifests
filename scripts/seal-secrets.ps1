<#
Seals all env files in `base/secrets` into SealedSecret manifests in `base/secrets`.
Requires: kubectl, kubeseal (https://github.com/bitnami-labs/sealed-secrets)
Usage: .\scripts\seal-secrets.ps1 [-Namespace <k8s namespace>]
Always fetches the controller cert and strips namespace fields so Kustomize can set them.

Examples:
  .env.billing              -> billing-sealedsecret.yaml (billing-secret)
  .env.elasticsearch        -> elasticsearch-sealedsecret.yaml (shared config only)

Elasticsearch users are emitted as individual kubernetes.io/basic-auth secrets.
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

function ConvertTo-SecretName {
    param(
        [string]$Value
    )

    return ($Value.ToLowerInvariant() -replace '[^a-z0-9-]', '-').Trim('-')
}

function Invoke-SealTempSecret {
    param(
        [string]$TempFile,
        [string]$OutFile,
        [string]$CertPath,
        [bool]$UseCert,
        [string]$TempPrefix
    )

    $sealedTemp = Join-Path $sealedDir "temp-$TempPrefix-sealedsecret.yaml"
    $sealArgs = @('--format', 'yaml', '--scope', 'cluster-wide')
    if ($UseCert) {
        $sealArgs += @('--cert', $CertPath)
    }

    Get-Content -Path $TempFile -Raw | & kubeseal @sealArgs | Set-Content -Path $sealedTemp -Encoding utf8
    if ($LASTEXITCODE -ne 0) {
        throw "kubeseal failed for $OutFile"
    }

    Get-Content -Path $sealedTemp | Where-Object { $_ -notmatch '^\s*namespace:\s*' } |
        Set-Content -Path $OutFile -Encoding utf8

    Remove-Item -Path $sealedTemp -ErrorAction SilentlyContinue
}

function Write-BasicAuthSecret {
    param(
        [string]$SecretName,
        [string]$UserName,
        [string]$Password,
        [string]$CertPath,
        [bool]$UseCert,
        [string]$Roles
    )

    $tempPrefix = $SecretName -replace '[^a-zA-Z0-9-]', '-'
    $tempFile = Join-Path $sealedDir "temp-$tempPrefix.yaml"
    $outFile = Join-Path $sealedDir "${SecretName}-sealedsecret.yaml"

    Write-Output "Sealing basic-auth user '$UserName' -> $outFile"

    $kubectlArgs = @(
        'create', 'secret', 'generic', $SecretName,
        '--type=kubernetes.io/basic-auth',
        "--from-literal=username=$UserName",
        "--from-literal=password=$Password",
        "--namespace=$Namespace",
        '--dry-run=client', '-o', 'yaml'
    )

    if ($Roles) {
        $kubectlArgs = @(
            'create', 'secret', 'generic', $SecretName,
            '--type=kubernetes.io/basic-auth',
            "--from-literal=username=$UserName",
            "--from-literal=password=$Password",
            "--from-literal=roles=$Roles",
            "--namespace=$Namespace",
            '--dry-run=client', '-o', 'yaml'
        )
    }

    Invoke-Checked -FilePath kubectl -Arguments $kubectlArgs | Set-Content -Path $tempFile -Encoding utf8
    Invoke-SealTempSecret -TempFile $tempFile -OutFile $outFile -CertPath $CertPath -UseCert:$UseCert -TempPrefix $tempPrefix
    Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
    Write-Output "Wrote $outFile"
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

# Also include any env files placed under gateway/secrets (for TLS/cluster gateway secrets)
$gatewaySecretsDir = Join-Path $repoRoot "gateway\secrets"
if (Test-Path $gatewaySecretsDir) {
    $gatewayEnvFiles = Get-ChildItem -Path $gatewaySecretsDir -File |
        Where-Object { $_.Name -like '.env.*' -and $_.Name -notlike '*.example' }
    if ($gatewayEnvFiles) {
        $envFiles = $envFiles + $gatewayEnvFiles
    }
}

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

    # Allow overriding the final secret name from the .env file using SECRET_NAME=<name>
    $envRaw = Get-Content -Path $envFile -Raw
    $secretNameMatch = [regex]::Match($envRaw, '^[ \t]*SECRET_NAME[ \t]*=[ \t]*(.+)$','Multiline')
    if ($secretNameMatch.Success) {
        $secretName = $secretNameMatch.Groups[1].Value.Trim()
    } else {
        $secretName = "${name}-secret"
    }

    $targetSecretName = $secretName
    $sealedBaseName = $targetSecretName
    if ($sealedBaseName -like '*-secret') {
        $sealedBaseName = $sealedBaseName -replace '-secret$', ''
    }

    # Decide output directory: prefer gateway/secrets when TLS input is under gateway/secrets
    $gatewaySecretsDir = Join-Path $repoRoot "gateway\secrets"
    $outDir = $sealedDir
    if ((Test-Path $gatewaySecretsDir) -and (Test-Path (Join-Path $gatewaySecretsDir ("${name}.crt")))) {
        $outDir = $gatewaySecretsDir
    }

    $safeTempName = $targetSecretName -replace '[^a-zA-Z0-9-]', '-'
    $outFile = Join-Path $outDir ("${sealedBaseName}-sealedsecret.yaml")
    $filteredEnvFile = Join-Path $sealedDir ("temp-${name}-${safeTempName}.env")
    $tempFile = Join-Path $sealedDir ("temp-${name}-${safeTempName}.yaml")

    Write-Output "Sealing '$envFile' as '$targetSecretName' -> $outFile"

    try {
        # Prefer TLS files stored under gateway/secrets (cluster gateway certs)
        $gatewaySecretsDir = Join-Path $repoRoot "gateway\secrets"
        $certFilePath = Join-Path $gatewaySecretsDir ("${name}.crt")
        $keyFilePath = Join-Path $gatewaySecretsDir ("${name}.key")

        # Fallback to base/secrets if gateway/secrets do not contain the files
        if ((-not (Test-Path $certFilePath)) -or (-not (Test-Path $keyFilePath))) {
            $certFilePath = Join-Path $secretsDir ("${name}.crt")
            $keyFilePath = Join-Path $secretsDir ("${name}.key")
        }

        if ((Test-Path $certFilePath) -and (Test-Path $keyFilePath)) {
            $kubectlArgs = @(
                'create','secret','tls',$targetSecretName,
                "--cert=$certFilePath",
                "--key=$keyFilePath",
                "--namespace=$Namespace",
                '--dry-run=client','-o','yaml'
            )
        } else {
            # Exclude auth-related values from the shared Elasticsearch config secret.
            if ($name -eq 'elasticsearch') {
                $envLines = Get-Content -Path $envFile
                $envLines | Where-Object {
                    $_ -notmatch '^[ \t]*(SECRET_NAME|FILE_REALM_SECRET_NAME|ELASTIC_PASSWORD|KIBANA_USERNAME|KIBANA_PASSWORD|[A-Z0-9_]+_ES_USER|[A-Z0-9_]+_ES_PASS|[A-Z0-9_]+_ES_ROLES)[ \t]*='
                } | Set-Content -Path $filteredEnvFile -Encoding utf8
            } else {
                $envLines = Get-Content -Path $envFile
                $envLines | Where-Object { $_ -notmatch '^[ \t]*SECRET_NAME[ \t]*=' } |
                    Set-Content -Path $filteredEnvFile -Encoding utf8
            }

            $kubectlArgs = @(
                'create','secret','generic',$targetSecretName,
                "--from-env-file=$filteredEnvFile",
                "--namespace=$Namespace",
                '--dry-run=client','-o','yaml'
            )
        }

        Invoke-Checked -FilePath kubectl -Arguments $kubectlArgs | Set-Content -Path $tempFile -Encoding utf8
        Invoke-SealTempSecret -TempFile $tempFile -OutFile $outFile -CertPath $certPath -UseCert:$useCert -TempPrefix $safeTempName

        Write-Output "Wrote $outFile"
    } catch {
        Write-Error "Failed sealing ${envFile}: $($_)"
    } finally {
        Remove-Item -Path $filteredEnvFile -ErrorAction SilentlyContinue
        Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
    }

    if ($name -eq 'elasticsearch') {
        $envMap = @{}
        foreach ($line in ($envRaw -split "`r?`n")) {
            if ($line -match '^[ \t]*([^=\s]+)[ \t]*=[ \t]*(.+)$') {
                $envMap[$matches[1]] = $matches[2].Trim()
            }
        }

        if ($envMap.ContainsKey('KIBANA_USERNAME') -and $envMap.ContainsKey('KIBANA_PASSWORD')) {
            Write-BasicAuthSecret -SecretName 'kibana-system-basic-auth' -UserName $envMap['KIBANA_USERNAME'] -Password $envMap['KIBANA_PASSWORD'] -CertPath $certPath -UseCert:$useCert
        } else {
            Write-Warning "KIBANA_USERNAME or KIBANA_PASSWORD not found in $envFile. Skipping kibana-system-basic-auth."
        }

        foreach ($key in @($envMap.Keys)) {
            if ($key -like '*_ES_USER') {
                $userName = $envMap[$key]
                $passKey = $key -replace '_ES_USER$', '_ES_PASS'
                $rolesKey = $key -replace '_ES_USER$', '_ES_ROLES'
                if ($envMap.ContainsKey($passKey)) {
                    $secretName = "$(ConvertTo-SecretName $userName)-basic-auth"
                    $rolesValue = $null
                    if ($envMap.ContainsKey($rolesKey)) {
                        $rolesValue = $envMap[$rolesKey]
                    }
                    Write-BasicAuthSecret -SecretName $secretName -UserName $userName -Password $envMap[$passKey] -CertPath $certPath -UseCert:$useCert -Roles $rolesValue
                } else {
                    Write-Warning "$passKey not found for user '$userName'. Skipping."
                }
            }
        }
    }
}

Write-Output "Done. Review files in base/secrets and commit them."