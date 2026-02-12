# =============================================================================
# Production Environment - Headscale Deployment
# =============================================================================
# NixOS-based deployment on OCI free tier with AWS Route53 DNS.
# All VMs have public IPs - no load balancer needed.

terraform {
  required_version = ">= 1.10.7"

  # Uncomment and configure for remote state storage
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "headscale/prod/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

# =============================================================================
# Local variables
# =============================================================================

locals {
  headscale_fqdn = "${var.headscale_subdomain}.${var.domain_name}"
  keycloak_fqdn  = "${var.keycloak_subdomain}.${var.domain_name}"
  derp_east_fqdn = "${var.derp_east_subdomain}.${var.domain_name}"
  derp_west_fqdn = "${var.derp_west_subdomain}.${var.domain_name}"
  tailnet_domain = "tail.${var.domain_name}"
}

# =============================================================================
# Network Module
# =============================================================================

module "network" {
  source = "../../modules/oci-network"

  compartment_ocid    = var.oci_compartment_ocid
  vcn_cidr_block      = var.vcn_cidr_block
  public_subnet_cidr  = var.public_subnet_cidr
  private_subnet_cidr = var.private_subnet_cidr
  project             = var.project
  environment         = var.environment
}

# =============================================================================
# Vault Module (Secrets Management)
# =============================================================================
# Stores database passwords that are shared between VMs.
# VMs fetch secrets at boot using instance principals.

module "vault" {
  source = "../../modules/oci-vault"

  compartment_ocid = var.oci_compartment_ocid
  tenancy_ocid     = var.oci_tenancy_ocid
  project          = var.project
  environment      = var.environment
}

# =============================================================================
# Compute Module (Primary Region - Ashburn)
# =============================================================================
# All VMs use NixOS custom images built via nixos-generators.
# PostgreSQL runs on the Keycloak VM as a native NixOS service.

module "compute" {
  source = "../../modules/oci-compute"

  compartment_ocid     = var.oci_compartment_ocid
  public_subnet_id     = module.network.public_subnet_id
  headscale_nsg_id     = module.network.headscale_nsg_id
  availability_domains = module.network.availability_domains
  ssh_public_key       = var.ssh_public_key

  # NixOS image OCIDs (built and imported separately)
  headscale_image_ocid = var.headscale_image_ocid
  derp_image_ocid      = var.derp_image_ocid
  keycloak_image_ocid  = var.keycloak_image_ocid

  # Compute shapes
  headscale_shape    = var.headscale_shape
  derp_shape         = var.derp_shape
  keycloak_shape     = var.keycloak_shape
  keycloak_ocpus      = var.keycloak_ocpus
  keycloak_memory_gb  = var.keycloak_memory_gb
  keycloak_private_ip = var.keycloak_private_ip

  # OCI Vault secret OCIDs (VMs fetch at boot via instance principals)
  keycloak_db_secret_id      = module.vault.keycloak_db_password_secret_id
  headscale_db_secret_id     = module.vault.headscale_db_password_secret_id
  keycloak_admin_secret_id   = module.vault.keycloak_admin_password_secret_id
  headscale_oidc_secret_id   = module.vault.headscale_oidc_secret_id
  headplane_cookie_secret_id = module.vault.headplane_cookie_secret_id
  derp_preauth_secret_id     = module.vault.derp_preauth_secret_id

  project     = var.project
  environment = var.environment
}

# =============================================================================
# DERP West Instance (Secondary Region - Phoenix)
# Only created when enable_secondary_region = true
# =============================================================================

# Network for Phoenix region
module "network_phoenix" {
  count  = var.enable_secondary_region ? 1 : 0
  source = "../../modules/oci-network"

  providers = {
    oci = oci.phoenix
  }

  compartment_ocid    = var.oci_compartment_ocid
  vcn_cidr_block      = "10.1.0.0/16"
  public_subnet_cidr  = "10.1.1.0/24"
  private_subnet_cidr = "10.1.2.0/24"
  project             = var.project
  environment         = var.environment
}

# DERP West compute instance
resource "oci_core_instance" "derp_west" {
  count    = var.enable_secondary_region ? 1 : 0
  provider = oci.phoenix

  compartment_id      = var.oci_compartment_ocid
  availability_domain = module.network_phoenix[0].availability_domains[0]
  display_name        = "${var.project}-derp-west"
  shape               = var.derp_shape

  # Note: E2.1.Micro is fixed size, no shape_config needed

  source_details {
    source_type = "image"
    source_id   = var.derp_west_image_ocid
  }

  create_vnic_details {
    subnet_id              = module.network_phoenix[0].public_subnet_id
    assign_public_ip       = true
    display_name           = "${var.project}-derp-west-vnic"
    hostname_label         = "derp-west"
    skip_source_dest_check = false
  }

  metadata = {
    ssh_authorized_keys    = var.ssh_public_key
    derp_preauth_secret_id = module.vault.derp_preauth_secret_id
  }

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
    Role        = "derp"
    Region      = "west"
    OS          = "NixOS"
  }
}

# =============================================================================
# DNS Module (AWS Route53)
# =============================================================================

module "dns" {
  source = "../../modules/aws-route53"

  route53_zone_id     = var.route53_zone_id
  domain_name         = var.domain_name
  headscale_subdomain = var.headscale_subdomain
  keycloak_subdomain  = var.keycloak_subdomain
  derp_east_subdomain = var.derp_east_subdomain
  derp_west_subdomain = var.derp_west_subdomain

  # Direct instance IPs (no load balancer)
  headscale_ip = module.compute.headscale_public_ip
  keycloak_ip  = module.compute.keycloak_public_ip
  derp_east_ip = module.compute.derp_east_public_ip
  derp_west_ip = var.enable_secondary_region ? oci_core_instance.derp_west[0].public_ip : ""

  enable_derp_west     = var.enable_secondary_region
  enable_health_checks = var.enable_dns_health_checks
  create_caa_record    = true
  project              = var.project
  environment          = var.environment
}

# =============================================================================
# Outputs
# =============================================================================

output "headscale_url" {
  description = "Headscale control plane URL"
  value       = "https://${module.dns.headscale_fqdn}"
}

output "keycloak_url" {
  description = "Keycloak admin URL"
  value       = "https://${module.dns.keycloak_fqdn}"
}

output "derp_servers" {
  description = "DERP relay server URLs"
  value = merge(
    { east = "https://${module.dns.derp_east_fqdn}" },
    var.enable_secondary_region ? { west = "https://${module.dns.derp_west_fqdn}" } : {}
  )
}

output "headscale_public_ip" {
  description = "Headscale instance public IP"
  value       = module.compute.headscale_public_ip
}

output "keycloak_public_ip" {
  description = "Keycloak instance public IP"
  value       = module.compute.keycloak_public_ip
}

output "keycloak_private_ip" {
  description = "Keycloak private IP (for Headscale DB connection in NixOS config)"
  value       = module.compute.keycloak_private_ip
}

output "derp_east_public_ip" {
  description = "DERP East instance public IP"
  value       = module.compute.derp_east_public_ip
}

output "derp_preauth_secret_id" {
  description = "OCI Vault secret OCID for DERP pre-auth key (update with actual key)"
  value       = module.vault.derp_preauth_secret_id
}
