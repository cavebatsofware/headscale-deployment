# =============================================================================
# AWS Route53 DNS Module
# =============================================================================
# Creates DNS records pointing directly to OCI instance public IPs.
# No load balancer - each service has its own public IP.

# Headscale DNS record (points directly to headscale instance)
resource "aws_route53_record" "headscale" {
  zone_id = var.route53_zone_id
  name    = "${var.headscale_subdomain}.${var.domain_name}"
  type    = "A"
  ttl     = 300

  records = [var.headscale_ip]
}

# Keycloak DNS record (points directly to keycloak instance)
resource "aws_route53_record" "keycloak" {
  zone_id = var.route53_zone_id
  name    = "${var.keycloak_subdomain}.${var.domain_name}"
  type    = "A"
  ttl     = 300

  records = [var.keycloak_ip]
}

# DERP East DNS record (points directly to DERP instance)
resource "aws_route53_record" "derp_east" {
  zone_id = var.route53_zone_id
  name    = "${var.derp_east_subdomain}.${var.domain_name}"
  type    = "A"
  ttl     = 300

  records = [var.derp_east_ip]
}

# DERP West DNS record (points directly to DERP instance)
resource "aws_route53_record" "derp_west" {
  count = var.enable_derp_west ? 1 : 0

  zone_id = var.route53_zone_id
  name    = "${var.derp_west_subdomain}.${var.domain_name}"
  type    = "A"
  ttl     = 300

  records = [var.derp_west_ip]
}

# =============================================================================
# Optional: Health Checks for DERP servers
# =============================================================================

resource "aws_route53_health_check" "derp_east" {
  count = var.enable_health_checks ? 1 : 0

  ip_address        = var.derp_east_ip
  port              = 443
  type              = "HTTPS"
  resource_path     = "/"
  failure_threshold = 3
  request_interval  = 30

  tags = {
    Name        = "${var.project}-derp-east-health"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_route53_health_check" "derp_west" {
  count = var.enable_health_checks && var.enable_derp_west ? 1 : 0

  ip_address        = var.derp_west_ip
  port              = 443
  type              = "HTTPS"
  resource_path     = "/"
  failure_threshold = 3
  request_interval  = 30

  tags = {
    Name        = "${var.project}-derp-west-health"
    Project     = var.project
    Environment = var.environment
  }
}

# =============================================================================
# CAA Records (for Let's Encrypt)
# =============================================================================

resource "aws_route53_record" "caa" {
  count = var.create_caa_record ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "CAA"
  ttl     = 3600

  records = [
    "0 issue \"letsencrypt.org\"",
    "0 issuewild \"letsencrypt.org\"",
  ]
}
