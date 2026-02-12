# OCI Vault secret fetch function
# Source this at the top of secrets-init scripts.
# Requires: curl, jq, oci-cli in PATH
# Requires: IMDS_BASE set to http://169.254.169.254/opc/v2
#
# Usage: fetch_secret <metadata_key> <output_path> <owner:group> [mode]
# Returns non-zero on failure.

fetch_secret() {
  local metadata_key="$1"
  local output_path="$2"
  local ownership="$3"
  local mode="${4:-0600}"
  umask 077

  if [ -f "$output_path" ]; then
    echo "$(basename "$output_path") already exists, skipping fetch"
    return 0
  fi

  local secret_id
  secret_id=$(curl -sf -H "Authorization: Bearer Oracle" \
    "$IMDS_BASE/instance/metadata/$metadata_key" || true)

  if [ -z "$secret_id" ]; then
    echo "ERROR: $metadata_key not found in instance metadata"
    return 1
  fi

  local content
  content=$(oci secrets secret-bundle get \
    --auth instance_principal \
    --secret-id "$secret_id" \
    --query 'data."secret-bundle-content".content' \
    --raw-output 2>/dev/null || true)

  if [ -z "$content" ]; then
    echo "ERROR: Failed to fetch $(basename "$output_path") from OCI Vault"
    return 1
  fi

  echo "$content" | base64 -d > "$output_path"
  chmod "$mode" "$output_path"
  chown "$ownership" "$output_path" 2>/dev/null || true
  echo "Fetched $(basename "$output_path") successfully"
  umask 644
}
