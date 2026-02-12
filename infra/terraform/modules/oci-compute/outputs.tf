# =============================================================================
# OCI Compute Module Outputs
# =============================================================================

# Headscale
output "headscale_instance_id" {
  description = "OCID of headscale instance"
  value       = oci_core_instance.headscale.id
}

output "headscale_public_ip" {
  description = "Public IP address of headscale instance"
  value       = oci_core_instance.headscale.public_ip
}

output "headscale_private_ip" {
  description = "Private IP address of headscale instance"
  value       = oci_core_instance.headscale.private_ip
}

# DERP East
output "derp_east_instance_id" {
  description = "OCID of DERP East instance"
  value       = oci_core_instance.derp_east.id
}

output "derp_east_public_ip" {
  description = "Public IP address of DERP East"
  value       = oci_core_instance.derp_east.public_ip
}

output "derp_east_private_ip" {
  description = "Private IP address of DERP East"
  value       = oci_core_instance.derp_east.private_ip
}

# Keycloak
output "keycloak_instance_id" {
  description = "OCID of Keycloak instance"
  value       = oci_core_instance.keycloak.id
}

output "keycloak_public_ip" {
  description = "Public IP address of Keycloak"
  value       = oci_core_instance.keycloak.public_ip
}

output "keycloak_private_ip" {
  description = "Private IP address of Keycloak (for Headscale DB connection)"
  value       = oci_core_instance.keycloak.private_ip
}

# Block Volumes
output "headscale_data_volume_id" {
  description = "OCID of headscale data volume"
  value       = oci_core_volume.headscale_data.id
}

output "keycloak_data_volume_id" {
  description = "OCID of keycloak data volume"
  value       = oci_core_volume.keycloak_data.id
}
