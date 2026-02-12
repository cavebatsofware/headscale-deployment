# =============================================================================
# Production Environment Variables
# =============================================================================

# =============================================================================
# OCI Authentication
# =============================================================================

variable "oci_tenancy_ocid" {
  description = "OCI tenancy OCID"
  type        = string
}

variable "oci_user_ocid" {
  description = "OCI user OCID"
  type        = string
}

variable "oci_fingerprint" {
  description = "OCI API key fingerprint"
  type        = string
}

variable "oci_private_key_path" {
  description = "Path to OCI API private key"
  type        = string
}

variable "oci_private_key_password" {
  description = "Password for OCI API private key (if encrypted)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "oci_region_primary" {
  description = "Primary OCI region"
  type        = string
  default     = "us-ashburn-1"
}

variable "oci_region_secondary" {
  description = "Secondary OCI region (for DERP West)"
  type        = string
  default     = "us-phoenix-1"
}

variable "oci_compartment_ocid" {
  description = "OCI compartment OCID"
  type        = string
}

# =============================================================================
# AWS Authentication
# =============================================================================

variable "aws_region" {
  description = "AWS region for Route53"
  type        = string
  default     = "us-east-1"
}

variable "aws_access_key" {
  description = "AWS access key ID (not used when using profile)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "aws_secret_key" {
  description = "AWS secret access key (not used when using profile)"
  type        = string
  sensitive   = true
  default     = ""
}

# =============================================================================
# Domain Configuration
# =============================================================================

variable "domain_name" {
  description = "Base domain name (e.g., example.com)"
  type        = string
}

variable "route53_zone_id" {
  description = "AWS Route53 hosted zone ID"
  type        = string
}

variable "headscale_subdomain" {
  description = "Subdomain for headscale"
  type        = string
  default     = "headscale"
}

variable "keycloak_subdomain" {
  description = "Subdomain for Keycloak"
  type        = string
  default     = "keycloak"
}

variable "derp_east_subdomain" {
  description = "Subdomain for DERP East"
  type        = string
  default     = "derp-east"
}

variable "derp_west_subdomain" {
  description = "Subdomain for DERP West"
  type        = string
  default     = "derp-west"
}

# =============================================================================
# Network Configuration
# =============================================================================

variable "vcn_cidr_block" {
  description = "VCN CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "Private subnet CIDR (for internal communication)"
  type        = string
  default     = "10.0.2.0/24"
}

# =============================================================================
# NixOS Image OCIDs
# =============================================================================
# These are custom images built via `nix build .#oci-*-image` and imported
# to OCI. After building, upload the QCOW2 to Object Storage and import
# as a custom image, then paste the OCID here.

variable "headscale_image_ocid" {
  description = "OCID of NixOS headscale image (AMD64 for E2.1.Micro)"
  type        = string
}

variable "derp_image_ocid" {
  description = "OCID of NixOS DERP image (ARM64 for A1.Flex)"
  type        = string
}

variable "keycloak_image_ocid" {
  description = "OCID of NixOS keycloak image (ARM64 for A1.Flex)"
  type        = string
}

variable "derp_west_image_ocid" {
  description = "OCID of NixOS DERP West image (ARM64, in Phoenix region)"
  type        = string
  default     = "" # Only needed if enable_secondary_region = true
}

# =============================================================================
# Compute Configuration
# =============================================================================

variable "headscale_shape" {
  description = "OCI shape for headscale (AMD64)"
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}

variable "derp_shape" {
  description = "OCI shape for DERP servers (AMD64 - E2.1.Micro free tier)"
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}

variable "keycloak_shape" {
  description = "OCI shape for keycloak (AMD64 - E4.Flex)"
  type        = string
  default     = "VM.Standard.E4.Flex"
}

variable "keycloak_ocpus" {
  description = "OCPUs for keycloak A1.Flex instance"
  type        = number
  default     = 2
}

variable "keycloak_memory_gb" {
  description = "Memory in GB for keycloak A1.Flex instance"
  type        = number
  default     = 12
}

variable "keycloak_private_ip" {
  description = "Static private IP for keycloak instance (must be in public subnet CIDR)"
  type        = string
  default     = "10.0.1.20"
}

variable "ssh_public_key" {
  description = "SSH public key for VM access"
  type        = string
}

# =============================================================================
# Feature Flags
# =============================================================================

variable "enable_dns_health_checks" {
  description = "Enable Route53 health checks for DERP servers"
  type        = bool
  default     = false
}

variable "enable_secondary_region" {
  description = "Enable Phoenix region for DERP West"
  type        = bool
  default     = false
}

# =============================================================================
# Tags
# =============================================================================

variable "project" {
  description = "Project name for resource tagging"
  type        = string
  default     = "headscale-deployment"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}
