# =============================================================================
# OCI Network Module - VCN, Subnets, Security Lists, Gateways
# =============================================================================

terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

# Virtual Cloud Network (VCN)
resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr_block]
  display_name   = "${var.project}-vcn"
  dns_label      = var.vcn_dns_label

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# Internet Gateway
resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project}-igw"
  enabled        = true

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# NAT Gateway for private subnet outbound access
resource "oci_core_nat_gateway" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project}-nat-gw"

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# Service Gateway for OCI services access
data "oci_core_services" "all_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_service_gateway" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project}-svc-gw"

  services {
    service_id = data.oci_core_services.all_services.services[0].id
  }

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# =============================================================================
# Route Tables
# =============================================================================

# Public Route Table
resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project}-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# Private Route Table
resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project}-private-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.main.id
  }

  route_rules {
    destination       = data.oci_core_services.all_services.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.main.id
  }

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# =============================================================================
# Security Lists
# =============================================================================

# Public Security List (for DERP, Load Balancer)
resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project}-public-sl"

  # Egress: Allow all outbound
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # Ingress: SSH (restricted to admin IPs in production)
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "SSH access"

    tcp_options {
      min = 22
      max = 22
    }
  }

  # Ingress: HTTPS (443) for DERP and headscale
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "HTTPS for DERP relay and headscale"

    tcp_options {
      min = 443
      max = 443
    }
  }

  # Ingress: HTTP (80) for Let's Encrypt ACME challenges
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "HTTP for ACME challenges"

    tcp_options {
      min = 80
      max = 80
    }
  }

  # Ingress: STUN (3478/UDP) for DERP
  ingress_security_rules {
    protocol    = "17" # UDP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "STUN for NAT traversal"

    udp_options {
      min = 3478
      max = 3478
    }
  }

  # Ingress: Headscale gRPC (50443)
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "Headscale gRPC"

    tcp_options {
      min = 50443
      max = 50443
    }
  }

  # Ingress: ICMP for connectivity testing
  ingress_security_rules {
    protocol    = "1" # ICMP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "ICMP ping"

    icmp_options {
      type = 8 # Echo request
    }
  }

  # Ingress: PostgreSQL from within VCN (headscale -> keycloak)
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.vcn_cidr_block
    stateless   = false
    description = "PostgreSQL from VCN"

    tcp_options {
      min = 5432
      max = 5432
    }
  }

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# Private Security List (for internal services)
resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project}-private-sl"

  # Egress: Allow all outbound
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # Ingress: All traffic from VCN
  ingress_security_rules {
    protocol    = "all"
    source      = var.vcn_cidr_block
    stateless   = false
    description = "All traffic within VCN"
  }

  # Ingress: Headscale API (8080) from load balancer
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.public_subnet_cidr
    stateless   = false
    description = "Headscale API from LB"

    tcp_options {
      min = 8080
      max = 8080
    }
  }

  # Ingress: Headscale metrics (9090) from VCN
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.vcn_cidr_block
    stateless   = false
    description = "Headscale metrics"

    tcp_options {
      min = 9090
      max = 9090
    }
  }

  # Ingress: Keycloak (8080) from load balancer
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.public_subnet_cidr
    stateless   = false
    description = "Keycloak from LB"

    tcp_options {
      min = 8080
      max = 8080
    }
  }

  # Ingress: PostgreSQL from headscale instances
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.vcn_cidr_block
    stateless   = false
    description = "PostgreSQL from headscale"

    tcp_options {
      min = 5432
      max = 5432
    }
  }

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# =============================================================================
# Subnets
# =============================================================================

# Get availability domains
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

# Public Subnet
resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.public_subnet_cidr
  display_name               = "${var.project}-public-subnet"
  dns_label                  = "public"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# Private Subnet
resource "oci_core_subnet" "private" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.private_subnet_cidr
  display_name               = "${var.project}-private-subnet"
  dns_label                  = "private"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# =============================================================================
# Network Security Group for Headscale
# =============================================================================

resource "oci_core_network_security_group" "headscale" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project}-headscale-nsg"

  freeform_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# NSG Rules for Headscale
resource "oci_core_network_security_group_security_rule" "headscale_api_ingress" {
  network_security_group_id = oci_core_network_security_group.headscale.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = var.public_subnet_cidr
  source_type               = "CIDR_BLOCK"
  description               = "Headscale API from LB"

  tcp_options {
    destination_port_range {
      min = 8080
      max = 8080
    }
  }
}

resource "oci_core_network_security_group_security_rule" "headscale_grpc_ingress" {
  network_security_group_id = oci_core_network_security_group.headscale.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Headscale gRPC"

  tcp_options {
    destination_port_range {
      min = 50443
      max = 50443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "headscale_egress" {
  network_security_group_id = oci_core_network_security_group.headscale.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Allow all egress"
}
