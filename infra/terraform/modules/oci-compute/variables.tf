# =============================================================================
# OCI Compute Module Variables
# =============================================================================

variable "compartment_ocid" {
  description = "OCID of the compartment"
  type        = string
}

variable "public_subnet_id" {
  description = "OCID of the public subnet"
  type        = string
}

variable "headscale_nsg_id" {
  description = "OCID of the headscale network security group"
  type        = string
}

variable "availability_domains" {
  description = "List of availability domains"
  type        = list(string)
}

variable "ssh_public_key" {
  description = "SSH public key for VM access"
  type        = string
}

variable "project" {
  description = "Project name for resource tagging"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

# =============================================================================
# NixOS Image OCIDs
# =============================================================================
# These are custom images built via nixos-generators and imported to OCI.
# Build with: nix build .#oci-headscale-image (etc.)
# Then upload QCOW2 to Object Storage and import as custom image.

variable "headscale_image_ocid" {
  description = "OCID of the NixOS headscale image (AMD64)"
  type        = string
}

variable "derp_image_ocid" {
  description = "OCID of the NixOS DERP image (AMD64)"
  type        = string
}

variable "keycloak_image_ocid" {
  description = "OCID of the NixOS keycloak image (AMD64)"
  type        = string
}

# =============================================================================
# Headscale configuration
# =============================================================================

variable "headscale_ad_index" {
  description = "Index of availability domain for headscale (0-based)"
  type        = number
  default     = 1 # AD-2 where E2.1.Micro is available
}

variable "headscale_shape" {
  description = "OCI compute shape for headscale"
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}

# =============================================================================
# DERP configuration
# =============================================================================

variable "derp_shape" {
  description = "OCI compute shape for DERP (E2.1.Micro for free tier)"
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}

# Note: derp_ocpus and derp_memory_gb removed - E2.1.Micro is fixed size

# =============================================================================
# Keycloak configuration
# =============================================================================

variable "keycloak_shape" {
  description = "OCI compute shape for Keycloak (E4.Flex for adequate RAM)"
  type        = string
  default     = "VM.Standard.E4.Flex"
}

variable "keycloak_ocpus" {
  description = "Number of OCPUs for Keycloak"
  type        = number
  default     = 1
}

variable "keycloak_memory_gb" {
  description = "Memory in GB for Keycloak (minimum 4GB for Keycloak+PostgreSQL)"
  type        = number
  default     = 4
}

variable "keycloak_private_ip" {
  description = "Static private IP for keycloak instance (must be in public subnet CIDR)"
  type        = string
  default     = "10.0.1.20"
}

# =============================================================================
# OCI Vault Secret OCIDs
# =============================================================================
# These secrets are created by the vault module and fetched by VMs at boot
# using instance principals (no credentials needed in the image).

variable "keycloak_db_secret_id" {
  description = "OCID of the Keycloak DB password secret in OCI Vault"
  type        = string
}

variable "headscale_db_secret_id" {
  description = "OCID of the Headscale DB password secret in OCI Vault"
  type        = string
}

variable "keycloak_admin_secret_id" {
  description = "OCID of the Keycloak admin password secret in OCI Vault"
  type        = string
}

variable "headscale_oidc_secret_id" {
  description = "OCID of the Headscale OIDC client secret in OCI Vault"
  type        = string
}

variable "headplane_cookie_secret_id" {
  description = "OCID of the Headplane cookie secret in OCI Vault"
  type        = string
}

variable "derp_preauth_secret_id" {
  description = "OCID of the DERP pre-auth key for Tailscale exit node"
  type        = string
}
