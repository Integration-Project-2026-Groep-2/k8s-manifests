This directory will contain SealedSecret manifests produced by `kubeseal`.

How to generate sealed secrets (Windows PowerShell):

1. Install `kubectl` and `kubeseal`.
2. From the repository root run (may require cluster access):

```powershell
# Fetch the controller cert once (optional but recommended)
kubeseal --fetch-cert > pub-cert.pem

# Seal all env files (automated script)
scripts\seal-secrets.ps1
```

The script `scripts\seal-secrets.ps1` creates SealedSecret manifests under this directory. Commit the generated SealedSecret YAMLs (they are safe to store in git).
