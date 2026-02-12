# =============================================================================
# Providers Configuration for Production Environment
# =============================================================================

terraform {
  required_version = ">= 1.10.7"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.37.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

# OCI Provider - Primary region (Ashburn)
provider "oci" {
  tenancy_ocid         = var.oci_tenancy_ocid
  user_ocid            = var.oci_user_ocid
  fingerprint          = var.oci_fingerprint
  private_key_path     = var.oci_private_key_path
  private_key_password = var.oci_private_key_password
  region               = var.oci_region_primary
}

# OCI Provider - Secondary region (Phoenix) for DERP West
provider "oci" {
  alias                = "phoenix"
  tenancy_ocid         = var.oci_tenancy_ocid
  user_ocid            = var.oci_user_ocid
  fingerprint          = var.oci_fingerprint
  private_key_path     = var.oci_private_key_path
  private_key_password = var.oci_private_key_password
  region               = var.oci_region_secondary
}

# AWS Provider for Route53 DNS management
provider "aws" {
  region  = var.aws_region
  profile = "headscale-deploy"
}
