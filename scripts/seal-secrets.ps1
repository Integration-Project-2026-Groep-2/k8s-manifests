<#
Seals all env files in `base/secrets` into SealedSecret manifests in `base/secrets`.
Requires: kubectl, kubeseal (https://github.com/bitnami-labs/sealed-secrets)
Usage: .\scripts\seal-secrets.ps1 [-Namespace <k8s namespace>]
Always fetches the controller cert and strips namespace fields so Kustomize can set them.

Examples:
  .env.billing              -> billing-sealedsecret.yaml (billing-secret)
  .env.htpasswd-facturatie  -> htpasswd-facturatie-sealedsecret.yaml (htpasswd-facturatie-secret)
  .env.htpasswd-kassa       -> htpasswd-kassa-sealedsecret.yaml (htpasswd-kassa-secret)
  .env.htpasswd-mailing     -> htpasswd-mailing-sealedsecret.yaml (htpasswd-mailing-secret)

For htpasswd authentication secrets, create .env files with:
  .env.htpasswd-<service>
  
Format the content as a single line base64-encoded htpasswd file:
  auth=<base64-encoded-htpasswd>

Or use the format (which kubectl will handle):
  HTPASSWD_DATA=user1:hashed_password1
  HTPASSWD_DATA=user2:hashed_password2
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
    $sealedTemp = Join-Path $sealedDir ("temp-${name}-${safeTempName}-sealedsecret.yaml")

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
            # Exclude SECRET_NAME from the generated secret data.
            $envLines = Get-Content -Path $envFile
            $envLines | Where-Object { $_ -notmatch '^[ \t]*SECRET_NAME[ \t]*=' } |
                Set-Content -Path $filteredEnvFile -Encoding utf8
            $kubectlArgs = @(
                'create','secret','generic',$targetSecretName,
                "--from-env-file=$filteredEnvFile",
                "--namespace=$Namespace",
                '--dry-run=client','-o','yaml'
            )
        }
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
        Remove-Item -Path $filteredEnvFile -ErrorAction SilentlyContinue
        Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
        Remove-Item -Path $sealedTemp -ErrorAction SilentlyContinue
    }

    if ($name -eq 'elasticsearch') {
        $fileRealmSecretName = 'elasticsearch-file-realm'
        $fileRealmBaseName = 'elasticsearch-file-realm'
        $fileRealmOutFile = Join-Path $sealedDir ("${fileRealmBaseName}-sealedsecret.yaml")
        $fileRealmUsersFile = Join-Path $sealedDir ("temp-${name}-file-realm-users.txt")
        $fileRealmRolesFile = Join-Path $sealedDir ("temp-${name}-file-realm-roles.txt")
        $fileRealmTemp = Join-Path $sealedDir ("temp-${name}-file-realm-secret.yaml")
        $fileRealmSealedTemp = Join-Path $sealedDir ("temp-${name}-file-realm-sealedsecret.yaml")

        $elasticPasswordMatch = [regex]::Match($envRaw, '^[ \t]*ELASTIC_PASSWORD[ \t]*=[ \t]*(.+)$','Multiline')
        if (-not $elasticPasswordMatch.Success) {
            Write-Warning "ELASTIC_PASSWORD not found in $envFile. Skipping $fileRealmSecretName."
        } else {
            $elasticPassword = $elasticPasswordMatch.Groups[1].Value.Trim()
            $fileRealmUsersLine = $null

            if ($elasticPassword -match '^\$2[aby]\$') {
                $fileRealmUsersLine = "elastic:$elasticPassword"
            } else {
                $hashLine = $null
                if (Get-Command htpasswd -ErrorAction SilentlyContinue) {
                    $hashLine = & htpasswd -nbB elastic $elasticPassword
                } elseif (Get-Command wsl -ErrorAction SilentlyContinue) {
                    $hashLine = & wsl -e htpasswd -nbB elastic $elasticPassword
                }

                if (-not $hashLine -or $LASTEXITCODE -ne 0) {
                    throw "htpasswd failed generating bcrypt hash for elastic. Install htpasswd or use WSL with apache2-utils."
                }

                $fileRealmUsersLine = $hashLine.Trim()
            }

            function Get-FileRealmLine {
                param(
                    [string]$UserName,
                    [string]$Password
                )

                if ($Password -match '^\$2[aby]\$') {
                    return "${UserName}:$Password"
                }

                $hashLine = $null
                if (Get-Command htpasswd -ErrorAction SilentlyContinue) {
                    $hashLine = & htpasswd -nbB $UserName $Password
                } elseif (Get-Command wsl -ErrorAction SilentlyContinue) {
                    $hashLine = & wsl -e htpasswd -nbB $UserName $Password
                }

                if (-not $hashLine -or $LASTEXITCODE -ne 0) {
                    throw "htpasswd failed generating bcrypt hash for $UserName."
                }

                return $hashLine.Trim()
            }

            $fileRealmLines = @($fileRealmUsersLine)
            $fileRealmUsers = @('elastic')

            $envLines = $envRaw -split "`r?`n"
            $envMap = @{}
            foreach ($line in $envLines) {
                if ($line -match '^[ \t]*([^=\s]+)[ \t]*=[ \t]*(.+)$') {
                    $envMap[$matches[1]] = $matches[2].Trim()
                }
            }

            foreach ($key in $envMap.Keys) {
                if ($key -like '*_ES_USER') {
                    $userName = $envMap[$key]
                    $passKey = $key -replace '_ES_USER$', '_ES_PASS'
                    if ($envMap.ContainsKey($passKey)) {
                        $userPass = $envMap[$passKey]
                        $fileRealmLines += (Get-FileRealmLine -UserName $userName -Password $userPass)
                        $fileRealmUsers += $userName
                    }
                }
            }

            $usersContent = $fileRealmLines -join "`n"
            $rolesContent = "superuser:" + ($fileRealmUsers -join ',')

            Write-Output "Sealing '$envFile' as '$fileRealmSecretName' -> $fileRealmOutFile"

            try {
                Set-Content -Path $fileRealmUsersFile -Value $usersContent -Encoding utf8
                Set-Content -Path $fileRealmRolesFile -Value $rolesContent -Encoding utf8

                $kubectlArgs = @(
                    'create','secret','generic',$fileRealmSecretName,
                    "--from-file=users=$fileRealmUsersFile",
                    "--from-file=users_roles=$fileRealmRolesFile",
                    "--namespace=$Namespace",
                    '--dry-run=client','-o','yaml'
                )
                Invoke-Checked -FilePath kubectl -Arguments $kubectlArgs | Set-Content -Path $fileRealmTemp -Encoding utf8

                $sealArgs = @('--format','yaml','--scope','cluster-wide')
                if ($useCert) {
                    $sealArgs += @('--cert',$certPath)
                }

                Get-Content -Path $fileRealmTemp -Raw | & kubeseal @sealArgs | Set-Content -Path $fileRealmSealedTemp -Encoding utf8
                if ($LASTEXITCODE -ne 0) {
                    throw "kubeseal failed for $envFile (file realm)"
                }

                # Remove explicit namespace lines so kustomize can inject dev/prod namespaces
                Get-Content -Path $fileRealmSealedTemp | Where-Object { $_ -notmatch '^\s*namespace:\s*' } |
                    Set-Content -Path $fileRealmOutFile -Encoding utf8

                Write-Output "Wrote $fileRealmOutFile"
            } catch {
                Write-Error "Failed sealing ${envFile} (file realm): $($_)"
            } finally {
                Remove-Item -Path $fileRealmUsersFile -ErrorAction SilentlyContinue
                Remove-Item -Path $fileRealmRolesFile -ErrorAction SilentlyContinue
                Remove-Item -Path $fileRealmTemp -ErrorAction SilentlyContinue
                Remove-Item -Path $fileRealmSealedTemp -ErrorAction SilentlyContinue
            }
        }
    }
}

Write-Output "Done. Review files in base/secrets and commit them."