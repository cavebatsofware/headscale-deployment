# =============================================================================
# OCI Compute Module - Headscale, DERP, Keycloak VMs
# =============================================================================
# All VMs use NixOS custom images and are in the public subnet with public IPs.
# NixOS handles all configuration declaratively - no cloud-init needed.
#
# Images are built via `nix build .#oci-*-image` and uploaded to OCI Object
# Storage, then imported as custom images.

terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

# =============================================================================
# Headscale Instance (AMD64 - E2.1.Micro Free Tier)
# =============================================================================

resource "oci_core_instance" "headscale" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domains[var.headscale_ad_index]
  display_name        = "${var.project}-headscale"
  shape               = var.headscale_shape

  source_details {
    source_type = "image"
    source_id   = var.headscale_image_ocid
  }

  create_vnic_details {
    subnet_id              = var.public_subnet_id
    assign_public_ip       = true
    display_name           = "${var.project}-headscale-vnic"
    hostname_label         = "headscale"
    nsg_ids                = [var.headscale_nsg_id]
    skip_source_dest_check = false
  }

  metadata = {
    ssh_authorized_keys        = var.ssh_public_key
    headscale_db_secret_id     = var.headscale_db_secret_id
    headscale_oidc_secret_id   = var.headscale_oidc_secret_id
    headplane_cookie_secret_id = var.headplane_cookie_secret_id
  }

  agent_config {
    is_monitoring_disabled = false
    is_management_disabled = false
    plugins_config {
      desired_state = "ENABLED"
      name          = "Compute Instance Monitoring"
    }
  }

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
    Role        = "headscale"
    OS          = "NixOS"
  }

  lifecycle {
    ignore_changes = [
      source_details[0].source_id, # Don't recreate on image updates
    ]
  }
}

# =============================================================================
# DERP East Instance (AMD64 - E2.1.Micro Free Tier)
# =============================================================================
# E2.1.Micro is a fixed-size shape, no shape_config needed

resource "oci_core_instance" "derp_east" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domains[var.headscale_ad_index] # Same AD as headscale (E2.1.Micro only available in AD-2)
  display_name        = "${var.project}-derp-east"
  shape               = var.derp_shape

  # Note: E2.1.Micro has fixed 1/8 OCPU and 1GB RAM, no shape_config needed

  source_details {
    source_type = "image"
    source_id   = var.derp_image_ocid
  }

  create_vnic_details {
    subnet_id              = var.public_subnet_id
    assign_public_ip       = true
    display_name           = "${var.project}-derp-east-vnic"
    hostname_label         = "derp-east"
    skip_source_dest_check = false
  }

  metadata = {
    ssh_authorized_keys    = var.ssh_public_key
    derp_preauth_secret_id = var.derp_preauth_secret_id
  }

  agent_config {
    is_monitoring_disabled = false
    is_management_disabled = false
    plugins_config {
      desired_state = "ENABLED"
      name          = "Compute Instance Monitoring"
    }
  }

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
    Role        = "derp"
    Region      = "east"
    OS          = "NixOS"
  }

  lifecycle {
    ignore_changes = [
      source_details[0].source_id,
    ]
  }
}

# =============================================================================
# Keycloak Instance (AMD64 - E4.Flex)
# =============================================================================
# Runs Keycloak + PostgreSQL via NixOS native services

resource "oci_core_instance" "keycloak" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domains[0]
  display_name        = "${var.project}-keycloak"
  shape               = var.keycloak_shape

  shape_config {
    ocpus         = var.keycloak_ocpus
    memory_in_gbs = var.keycloak_memory_gb
  }

  source_details {
    source_type = "image"
    source_id   = var.keycloak_image_ocid
  }

  create_vnic_details {
    subnet_id              = var.public_subnet_id
    assign_public_ip       = true
    private_ip             = var.keycloak_private_ip
    display_name           = "${var.project}-keycloak-vnic"
    hostname_label         = "keycloak"
    skip_source_dest_check = false
  }

  metadata = {
    ssh_authorized_keys       = var.ssh_public_key
    keycloak_db_secret_id     = var.keycloak_db_secret_id
    headscale_db_secret_id    = var.headscale_db_secret_id
    keycloak_admin_secret_id  = var.keycloak_admin_secret_id
  }

  agent_config {
    is_monitoring_disabled = false
    is_management_disabled = false
    plugins_config {
      desired_state = "ENABLED"
      name          = "Compute Instance Monitoring"
    }
  }

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
    Role        = "keycloak"
    OS          = "NixOS"
  }

  lifecycle {
    ignore_changes = [
      source_details[0].source_id,
    ]
  }
}

# =============================================================================
# Block Volumes for persistent storage
# =============================================================================
# These volumes are labeled in NixOS configs for mounting:
# - headscale-data -> /var/lib/headscale
# - keycloak-data -> /var/lib/postgresql

resource "oci_core_volume" "headscale_data" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domains[var.headscale_ad_index]
  display_name        = "${var.project}-headscale-data"
  size_in_gbs         = 50 # OCI minimum is 50GB
  vpus_per_gb         = 10 # Balanced performance

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
    Role        = "headscale-data"
  }
}

resource "oci_core_volume_attachment" "headscale_data" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.headscale.id
  volume_id       = oci_core_volume.headscale_data.id
  display_name    = "${var.project}-headscale-data-attachment"
}

resource "oci_core_volume" "keycloak_data" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domains[0]
  display_name        = "${var.project}-keycloak-data"
  size_in_gbs         = 50 # OCI minimum is 50GB
  vpus_per_gb         = 10 # Balanced performance

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
    Role        = "keycloak-data"
  }
}

resource "oci_core_volume_attachment" "keycloak_data" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.keycloak.id
  volume_id       = oci_core_volume.keycloak_data.id
  display_name    = "${var.project}-keycloak-data-attachment"
}
