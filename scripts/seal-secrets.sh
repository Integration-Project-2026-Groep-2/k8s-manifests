#!/usr/bin/env bash
set -euo pipefail

# Seals all env files in base/secrets into SealedSecret manifests in base/secrets.
# Requires: kubectl, kubeseal
# Usage: ./scripts/seal-secrets.sh [namespace]
# Always fetches the controller cert and strips namespace fields so Kustomize can set them.

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

# htpasswd is only needed when a plaintext password must be bcrypt-hashed.
# We check here once so the script fails early rather than mid-loop.
_htpasswd_available=false
if command -v htpasswd >/dev/null 2>&1; then
  _htpasswd_available=true
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

# Read a single key=value from an env file, preserving values that contain '='.
get_env_value() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" 'BEGIN{found=0} $1==k{print substr($0, index($0,$2)); found=1} END{if(!found) exit 1}' "$file" 2>/dev/null
}

# Returns 0 (true) when the argument is a valid bcrypt hash ($2b/2a/2y + cost + 53-char hash).
is_bcrypt_hash() {
  [[ "$1" =~ ^\$2[aby]?\$[0-9]{2}\$.{53}$ ]]
}

# Bcrypt-hash a plaintext password; exits if htpasswd is unavailable.
bcrypt_hash() {
  local username="$1"
  local password="$2"
  if [[ "$_htpasswd_available" != true ]]; then
    echo "htpasswd not found in PATH. Install apache2-utils (Debian/Ubuntu) or httpd-tools (RHEL)." >&2
    exit 2
  fi
  htpasswd -nbB "$username" "$password" | tr -d '\r'
}

# Inject the ECK label into a plain Kubernetes Secret YAML so that the
# resulting SealedSecret carries the label for easier cluster-side discovery.
# Requires python3 + PyYAML; silently skipped when unavailable.
inject_eck_label() {
  local file="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  python3 - "$file" <<'PYEOF'
import sys, os
try:
    import yaml
except ImportError:
    sys.exit(0)

path = sys.argv[1]
with open(path) as fh:
    doc = yaml.safe_load(fh)

doc.setdefault("metadata", {}).setdefault("labels", {})
doc["metadata"]["labels"]["common.k8s.elastic.co/type"] = "elasticsearch"

tmp = path + ".ecklabeled"
with open(tmp, "w") as fh:
    yaml.dump(doc, fh, default_flow_style=False)
os.replace(tmp, path)
PYEOF
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
  sealed_temp="$sealed_dir/temp-${name}-${safe_temp_name}-sealedsecret.yaml"

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
    grep -vE '^[[:space:]]*SECRET_NAME[[:space:]]*=' "$env_file" > "$filtered_env"
    kubectl create secret generic "$secret_name" \
      --from-env-file="$filtered_env" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml > "$temp_file"
  fi

  seal_args=(--format yaml --scope cluster-wide)
  if [[ "$use_cert" == true ]]; then
    seal_args+=(--cert "$cert_path")
  fi

  kubeseal "${seal_args[@]}" < "$temp_file" > "$sealed_temp"

  grep -vE '^[[:space:]]*namespace:[[:space:]]*' "$sealed_temp" > "$out_file"
  echo "Wrote $out_file"

  rm -f "$filtered_env" "$temp_file" "$sealed_temp"

  # ── ECK file-realm bootstrap (only for the elasticsearch env file) ──────────
  if [[ "$name" == "elasticsearch" ]]; then

    # Allow overriding the secret name from the env file.
    if file_realm_name=$(get_env_value "$env_file" "FILE_REALM_SECRET_NAME" 2>/dev/null); then
      file_realm_name="${file_realm_name//[[:space:]]/}"
    else
      file_realm_name="elasticsearch-file-realm"
    fi

    file_realm_base="${file_realm_name%-secret}"
    file_realm_out="$sealed_dir/${file_realm_base}-sealedsecret.yaml"

    users_file="$sealed_dir/temp-${name}-file-realm-users.txt"
    roles_file="$sealed_dir/temp-${name}-file-realm-roles.txt"
    realm_temp="$sealed_dir/temp-${name}-file-realm-secret.yaml"
    realm_sealed="$sealed_dir/temp-${name}-file-realm-sealedsecret.yaml"

    # Ensure temp files are always cleaned up even on error.
    trap 'rm -f "$users_file" "$roles_file" "$realm_temp" "$realm_sealed"' RETURN

    if ! elastic_password=$(get_env_value "$env_file" "ELASTIC_PASSWORD" 2>/dev/null); then
      echo "Warning: ELASTIC_PASSWORD not found in $env_file. Skipping $file_realm_name." >&2
      continue
    fi

    # ── Build users file ───────────────────────────────────────────────────────
    users_lines=()

    if is_bcrypt_hash "$elastic_password"; then
      users_lines+=("elastic:${elastic_password}")
    else
      users_lines+=("$(bcrypt_hash "elastic" "$elastic_password")")
    fi

    # ── Build roles map (role -> comma-separated list of usernames) ────────────
    # We represent the map as a flat array of "role:userlist" strings and
    # update it with a helper so we stay compatible with bash 3 (macOS).
    roles_entries=()

    # Append a username to an existing role entry, or create a new one.
    roles_add_user() {
      local role="$1"
      local user="$2"
      local i
      for (( i = 0; i < ${#roles_entries[@]}; i++ )); do
        if [[ "${roles_entries[$i]%%:*}" == "$role" ]]; then
          roles_entries[$i]="${roles_entries[$i]},${user}"
          return
        fi
      done
      roles_entries+=("${role}:${user}")
    }

    # The built-in elastic user is always a superuser.
    roles_add_user "superuser" "elastic"

    # ── Additional users ───────────────────────────────────────────────────────
    while IFS='=' read -r key value; do
      key="${key//[[:space:]]/}"
      # Skip blank lines, comments, and keys without a value.
      [[ -z "$key" || "$key" == \#* ]] && continue

      if [[ "$key" == *_ES_USER ]]; then
        prefix="${key%_ES_USER}"
        user_name="${value//[[:space:]]/}"
        pass_key="${prefix}_ES_PASS"
        roles_key="${prefix}_ES_ROLES"

        if ! user_pass=$(get_env_value "$env_file" "$pass_key" 2>/dev/null); then
          echo "Warning: $pass_key not found for user '$user_name'. Skipping." >&2
          continue
        fi

        # Hash password if it is not already a bcrypt hash.
        if is_bcrypt_hash "$user_pass"; then
          users_lines+=("${user_name}:${user_pass}")
        else
          users_lines+=("$(bcrypt_hash "$user_name" "$user_pass")")
        fi

        # Resolve roles; default to superuser when the key is absent.
        if user_roles_raw=$(get_env_value "$env_file" "$roles_key" 2>/dev/null); then
          user_roles="${user_roles_raw//[[:space:]]/}"
        else
          user_roles="superuser"
        fi

        # Iterate over the comma-separated role list.
        IFS=',' read -ra role_list <<< "$user_roles"
        for role in "${role_list[@]}"; do
          role="${role//[[:space:]]/}"
          [[ -z "$role" ]] && continue
          roles_add_user "$role" "$user_name"
        done
      fi
    done < <(grep -vE '^[[:space:]]*#' "$env_file")

    # ── Write users and users_roles files ─────────────────────────────────────
    printf "%s\n" "${users_lines[@]}" > "$users_file"

    # ECK requires one line per role: "role_name:user1,user2"
    printf "%s\n" "${roles_entries[@]}" > "$roles_file"

    # ── Create the raw Kubernetes Secret and inject the ECK label ─────────────
    kubectl create secret generic "$file_realm_name" \
      --from-file=users="$users_file" \
      --from-file=users_roles="$roles_file" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml > "$realm_temp"

    inject_eck_label "$realm_temp"

    # ── Seal and strip namespace ───────────────────────────────────────────────
    kubeseal "${seal_args[@]}" < "$realm_temp" > "$realm_sealed"
    grep -vE '^[[:space:]]*namespace:[[:space:]]*' "$realm_sealed" > "$file_realm_out"

    echo "Wrote $file_realm_out"
    echo ""
    echo "  Remember to reference this secret in your Elasticsearch CRD:"
    echo "    spec:"
    echo "      auth:"
    echo "        fileRealm:"
    echo "          - secretName: ${file_realm_name}"
    echo ""

    # Clean up (also covered by the trap above).
    rm -f "$users_file" "$roles_file" "$realm_temp" "$realm_sealed"
    trap - RETURN
  fi

done

echo "Done. Review files in base/secrets and commit them."