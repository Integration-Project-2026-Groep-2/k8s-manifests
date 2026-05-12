#!/usr/bin/env bash
set -euo pipefail

# Seals all env files in base/secrets into SealedSecret manifests in base/secrets.
# Requires: kubectl, kubeseal, docker
# Usage: ./scripts/seal-secrets.sh [namespace]
# Always fetches the controller cert and strips namespace fields so Kustomize can set them.
# Elasticsearch users are emitted as individual kubernetes.io/basic-auth secrets.

NAMESPACE="${1:-integration-project-2026-groep-2}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$script_dir")"
secrets_dir="$repo_root/base/secrets"
sealed_dir="$repo_root/base/secrets"
gateway_secrets_dir="$repo_root/gateway/secrets"

# ── Dependency checks ────────────────────────────────────────────────────────

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found in PATH" >&2
  exit 2
fi
if ! command -v kubeseal >/dev/null 2>&1; then
  echo "kubeseal not found in PATH" >&2
  exit 2
fi

mkdir -p "$sealed_dir"

# ── Fetch Sealed Secrets controller cert ─────────────────────────────────────

cert_path="$sealed_dir/pub-cert.pem"

echo "Fetching Sealed Secrets controller cert from cluster..."
kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  --fetch-cert > "$cert_path"

use_cert=false
if command -v openssl >/dev/null 2>&1; then
  if openssl x509 -in "$cert_path" -noout >/dev/null 2>&1; then
    use_cert=true
  else
    echo "Warning: Cert file '$cert_path' is not a valid X509 certificate. Falling back to controller RPC." >&2
  fi
else
  echo "Warning: openssl not found, falling back to controller RPC." >&2
fi

shopt -s nullglob

env_files=("$secrets_dir"/.env.*)
if [[ -d "$gateway_secrets_dir" ]]; then
  env_files+=("$gateway_secrets_dir"/.env.*)
fi

if [[ ${#env_files[@]} -eq 0 ]]; then
  echo "Warning: No .env files found in $secrets_dir" >&2
  exit 0
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

sanitize_secret_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-'
}

seal_temp_secret() {
  local temp_file="$1"
  local out_file="$2"
  local temp_name="$3"
  local sealed_temp="$sealed_dir/temp-${temp_name}-sealedsecret.yaml"

  seal_args=(--format yaml --scope cluster-wide)
  if [[ "$use_cert" == true ]]; then
    seal_args+=(--cert "$cert_path")
  fi

  kubeseal "${seal_args[@]}" < "$temp_file" > "$sealed_temp"
  grep -vE '^[[:space:]]*namespace:[[:space:]]*' "$sealed_temp" > "$out_file"
  rm -f "$sealed_temp"
}

emit_basic_auth_secret() {
  local secret_name="$1"
  local username="$2"
  local password="$3"
  local roles="${4:-}"
  local temp_name="${secret_name//[^a-zA-Z0-9-]/-}"
  local temp_file="$sealed_dir/temp-${temp_name}.yaml"
  local out_file="$sealed_dir/${secret_name}-sealedsecret.yaml"

  echo "Sealing basic-auth user '$username' -> $out_file"

  if [[ -n "$roles" ]]; then
    kubectl create secret generic "$secret_name" \
      --type=kubernetes.io/basic-auth \
      --from-literal=username="$username" \
      --from-literal=password="$password" \
      --from-literal=roles="$roles" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml > "$temp_file"
  else
    kubectl create secret generic "$secret_name" \
      --type=kubernetes.io/basic-auth \
      --from-literal=username="$username" \
      --from-literal=password="$password" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml > "$temp_file"
  fi

  seal_temp_secret "$temp_file" "$out_file" "$temp_name"
  echo "Wrote $out_file"
  rm -f "$temp_file"
}

# Read a single key=value from an env file, preserving values that contain '='.
# Surrounding single or double quotes are stripped from the returned value so
# quoted env values do not keep the wrapping quotes.
get_env_value() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '
    BEGIN { found = 0 }
    $1 == k {
      val = substr($0, index($0, $2))
      if      (val ~ /^".*"$/)   val = substr(val, 2, length(val) - 2)
      else if (val ~ /^'"'"'.*'"'"'$/) val = substr(val, 2, length(val) - 2)
      print val
      found = 1
    }
    END { if (!found) exit 1 }
  ' "$file" 2>/dev/null
}

# ── Main loop ─────────────────────────────────────────────────────────────────

for env_file in "${env_files[@]}"; do
  [[ -f "$env_file" ]] || continue

  file_name="$(basename "$env_file")"
  if [[ "$file_name" == .env.* ]]; then
    name="${file_name:5}"
  else
    name="${file_name%.*}"
  fi
  if [[ -z "$name" ]]; then
    name="${file_name#.}"
  fi

  if secret_name=$(get_env_value "$env_file" "SECRET_NAME" 2>/dev/null); then
    secret_name="${secret_name//[[:space:]]/}"
  else
    secret_name="${name}-secret"
  fi

  sealed_base_name="$secret_name"
  if [[ "$sealed_base_name" == *-secret ]]; then
    sealed_base_name="${sealed_base_name%-secret}"
  fi

  out_dir="$sealed_dir"
  if [[ -d "$gateway_secrets_dir" && -f "$gateway_secrets_dir/${name}.crt" ]]; then
    out_dir="$gateway_secrets_dir"
  fi

  safe_temp_name="${secret_name//[^a-zA-Z0-9-]/-}"
  out_file="$out_dir/${sealed_base_name}-sealedsecret.yaml"
  filtered_env="$sealed_dir/temp-${name}-${safe_temp_name}.env"
  temp_file="$sealed_dir/temp-${name}-${safe_temp_name}.yaml"

  echo "Sealing '$env_file' as '$secret_name' -> $out_file"

  cert_file="$gateway_secrets_dir/${name}.crt"
  key_file="$gateway_secrets_dir/${name}.key"
  if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
    cert_file="$secrets_dir/${name}.crt"
    key_file="$secrets_dir/${name}.key"
  fi

  if [[ -f "$cert_file" && -f "$key_file" ]]; then
    kubectl create secret tls "$secret_name" \
      --cert="$cert_file" \
      --key="$key_file" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml > "$temp_file"
  else
    if [[ "$name" == "elasticsearch" ]]; then
      grep -vE '^[[:space:]]*(SECRET_NAME|FILE_REALM_SECRET_NAME|ELASTIC_PASSWORD|KIBANA_USERNAME|KIBANA_PASSWORD|[A-Z0-9_]+_ES_USER|[A-Z0-9_]+_ES_PASS|[A-Z0-9_]+_ES_ROLES)[[:space:]]*=' "$env_file" > "$filtered_env"
    else
      grep -vE '^[[:space:]]*SECRET_NAME[[:space:]]*=' "$env_file" > "$filtered_env"
    fi

    kubectl create secret generic "$secret_name" \
      --from-env-file="$filtered_env" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml > "$temp_file"
  fi

  seal_temp_secret "$temp_file" "$out_file" "$safe_temp_name"
  echo "Wrote $out_file"

  rm -f "$filtered_env" "$temp_file"

  if [[ "$name" == "elasticsearch" ]]; then
    if kibana_username=$(get_env_value "$env_file" "KIBANA_USERNAME" 2>/dev/null); then
      if kibana_password=$(get_env_value "$env_file" "KIBANA_PASSWORD" 2>/dev/null); then
        emit_basic_auth_secret "kibana-system-basic-auth" "$kibana_username" "$kibana_password"
      else
        echo "Warning: KIBANA_PASSWORD not found in $env_file. Skipping kibana-system-basic-auth." >&2
      fi
    fi

    while IFS='=' read -r key value; do
      key="${key//[[:space:]]/}"
      [[ -z "$key" || "$key" == \#* ]] && continue

      if [[ "$key" == *_ES_USER ]]; then
        prefix="${key%_ES_USER}"
        user_name="${value//[[:space:]]/}"
        pass_key="${prefix}_ES_PASS"
        roles_key="${prefix}_ES_ROLES"
        user_secret_name="$(sanitize_secret_name "$user_name")-basic-auth"

        if ! user_pass=$(get_env_value "$env_file" "$pass_key" 2>/dev/null); then
          echo "Warning: $pass_key not found for user '$user_name'. Skipping." >&2
          continue
        fi

        if user_roles_raw=$(get_env_value "$env_file" "$roles_key" 2>/dev/null); then
          user_roles="${user_roles_raw//[[:space:]]/}"
        else
          user_roles=""
        fi

        emit_basic_auth_secret "$user_secret_name" "$user_name" "$user_pass" "$user_roles"
      fi
    done < <(grep -vE '^[[:space:]]*#' "$env_file")
  fi

done

echo "Done. Review files in base/secrets and commit them."