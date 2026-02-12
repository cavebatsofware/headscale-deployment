# =============================================================================
# OCI Vault Module - Secrets Management
# =============================================================================
# Creates an OCI Vault with secrets for cross-VM authentication.
# VMs use instance principals to fetch secrets at boot time.

terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

# =============================================================================
# Vault
# =============================================================================

resource "oci_kms_vault" "main" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.project}-vault"
  vault_type     = "DEFAULT"

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# Master encryption key for secrets
resource "oci_kms_key" "secrets" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.project}-secrets-key"
  management_endpoint = oci_kms_vault.main.management_endpoint

  key_shape {
    algorithm = "AES"
    length    = 32
  }

  protection_mode = "SOFTWARE"

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# =============================================================================
# Generate Random Passwords
# =============================================================================

resource "random_password" "keycloak_db" {
  length  = 32
  special = false
}

resource "random_password" "headscale_db" {
  length  = 32
  special = false
}

resource "random_password" "keycloak_admin" {
  length  = 32
  special = false
}

resource "random_password" "headplane_cookie" {
  length  = 32
  special = false
}

# =============================================================================
# Secrets
# =============================================================================

resource "oci_vault_secret" "keycloak_db_password" {
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.main.id
  key_id         = oci_kms_key.secrets.id
  secret_name    = "${var.project}-keycloak-db-password"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(random_password.keycloak_db.result)
  }

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

resource "oci_vault_secret" "headscale_db_password" {
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.main.id
  key_id         = oci_kms_key.secrets.id
  secret_name    = "${var.project}-headscale-db-password"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(random_password.headscale_db.result)
  }

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

resource "oci_vault_secret" "keycloak_admin_password" {
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.main.id
  key_id         = oci_kms_key.secrets.id
  secret_name    = "${var.project}-keycloak-admin-password"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(random_password.keycloak_admin.result)
  }

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# OIDC client secret - update this in OCI Console after creating the Keycloak client
# The placeholder value will be replaced with the real secret from Keycloak
resource "oci_vault_secret" "headscale_oidc_secret" {
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.main.id
  key_id         = oci_kms_key.secrets.id
  secret_name    = "${var.project}-headscale-oidc-secret"

  secret_content {
    content_type = "BASE64"
    content      = base64encode("PLACEHOLDER_UPDATE_AFTER_KEYCLOAK_CLIENT_CREATED")
  }

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }

  lifecycle {
    ignore_changes = [secret_content]  # Don't overwrite manual updates
  }
}

# Headplane cookie secret for session encryption
resource "oci_vault_secret" "headplane_cookie_secret" {
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.main.id
  key_id         = oci_kms_key.secrets.id
  secret_name    = "${var.project}-headplane-cookie-secret"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(random_password.headplane_cookie.result)
  }

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# DERP pre-auth key for Tailscale exit node
# Created manually on Headscale server, then stored here via OCI CLI:
#   headscale preauthkeys create --user infraexit -o json | jq -r '.key'
#   oci vault secret update-base64 --secret-id <ocid> --secret-content-content "$(echo -n '<key>' | base64)"
resource "oci_vault_secret" "derp_preauth" {
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.main.id
  key_id         = oci_kms_key.secrets.id
  secret_name    = "${var.project}-derp-preauth-key"

  secret_content {
    content_type = "BASE64"
    content      = base64encode("PLACEHOLDER_UPDATE_WITH_HEADSCALE_PREAUTH_KEY")
  }

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }

  lifecycle {
    ignore_changes = [secret_content] # Don't overwrite manual updates
  }
}

# =============================================================================
# IAM Dynamic Group for Instance Principals
# =============================================================================
# Allows VMs to authenticate to OCI services without credentials

resource "oci_identity_dynamic_group" "vault_readers" {
  compartment_id = var.tenancy_ocid
  name           = "${var.project}-vault-readers"
  description    = "Instances that can read vault secrets"

  matching_rule = "ANY {instance.compartment.id = '${var.compartment_ocid}'}"

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# =============================================================================
# IAM Policy for Secret Access
# =============================================================================

resource "oci_identity_policy" "vault_read" {
  compartment_id = var.tenancy_ocid
  name           = "${var.project}-vault-read-policy"
  description    = "Allow project instances to read vault secrets"

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.vault_readers.name} to read secret-family in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.vault_readers.name} to use keys in compartment id ${var.compartment_ocid}",
  ]

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}
