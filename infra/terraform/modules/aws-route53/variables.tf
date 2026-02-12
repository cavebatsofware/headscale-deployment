# =============================================================================
# AWS Route53 DNS Module Variables
# =============================================================================

variable "route53_zone_id" {
  description = "AWS Route53 hosted zone ID"
  type        = string
}

variable "domain_name" {
  description = "Base domain name"
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
# Instance IPs (direct, no load balancer)
# =============================================================================

variable "headscale_ip" {
  description = "Public IP of the headscale instance"
  type        = string
}

variable "keycloak_ip" {
  description = "Public IP of the keycloak instance"
  type        = string
}

variable "derp_east_ip" {
  description = "Public IP of DERP East server"
  type        = string
}

variable "derp_west_ip" {
  description = "Public IP of DERP West server"
  type        = string
  default     = ""
}

# =============================================================================
# Feature flags
# =============================================================================

variable "enable_derp_west" {
  description = "Enable DERP West DNS record"
  type        = bool
  default     = false
}

variable "enable_health_checks" {
  description = "Enable Route53 health checks for DERP servers"
  type        = bool
  default     = false
}

variable "create_caa_record" {
  description = "Create CAA record for Let's Encrypt"
  type        = bool
  default     = true
}

# =============================================================================
# Tags
# =============================================================================

variable "project" {
  description = "Project name for resource tagging"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}
