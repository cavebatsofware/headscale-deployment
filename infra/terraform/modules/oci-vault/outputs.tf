# =============================================================================
# OCI Vault Module Outputs
# =============================================================================

output "vault_id" {
  description = "OCI Vault OCID"
  value       = oci_kms_vault.main.id
}

output "keycloak_db_password_secret_id" {
  description = "Secret OCID for Keycloak DB password"
  value       = oci_vault_secret.keycloak_db_password.id
}

output "headscale_db_password_secret_id" {
  description = "Secret OCID for Headscale DB password"
  value       = oci_vault_secret.headscale_db_password.id
}

output "keycloak_admin_password_secret_id" {
  description = "Secret OCID for Keycloak admin password"
  value       = oci_vault_secret.keycloak_admin_password.id
}

output "headscale_oidc_secret_id" {
  description = "Secret OCID for Headscale OIDC client secret"
  value       = oci_vault_secret.headscale_oidc_secret.id
}

output "headplane_cookie_secret_id" {
  description = "Secret OCID for Headplane cookie secret"
  value       = oci_vault_secret.headplane_cookie_secret.id
}

output "derp_preauth_secret_id" {
  description = "Secret OCID for DERP pre-auth key (Tailscale exit node)"
  value       = oci_vault_secret.derp_preauth.id
}

# These are the secret OCIDs that VMs need to fetch at boot
output "secret_ids" {
  description = "Map of secret names to OCIDs for VM configuration"
  value = {
    keycloak_db_password      = oci_vault_secret.keycloak_db_password.id
    headscale_db_password     = oci_vault_secret.headscale_db_password.id
    keycloak_admin_password   = oci_vault_secret.keycloak_admin_password.id
    headscale_oidc_secret     = oci_vault_secret.headscale_oidc_secret.id
    headplane_cookie_secret   = oci_vault_secret.headplane_cookie_secret.id
    derp_preauth              = oci_vault_secret.derp_preauth.id
  }
}
