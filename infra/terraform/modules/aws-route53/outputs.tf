output "headscale_fqdn" {
  description = "FQDN for headscale"
  value       = aws_route53_record.headscale.fqdn
}

output "keycloak_fqdn" {
  description = "FQDN for Keycloak"
  value       = aws_route53_record.keycloak.fqdn
}

output "derp_east_fqdn" {
  description = "FQDN for DERP East"
  value       = aws_route53_record.derp_east.fqdn
}

output "derp_west_fqdn" {
  description = "FQDN for DERP West"
  value       = var.enable_derp_west ? aws_route53_record.derp_west[0].fqdn : ""
}

output "headscale_record_name" {
  description = "Name of the headscale DNS record"
  value       = aws_route53_record.headscale.name
}

output "dns_records" {
  description = "Map of all DNS records created"
  value = merge(
    {
      headscale = aws_route53_record.headscale.fqdn
      keycloak  = aws_route53_record.keycloak.fqdn
      derp_east = aws_route53_record.derp_east.fqdn
    },
    var.enable_derp_west ? { derp_west = aws_route53_record.derp_west[0].fqdn } : {}
  )
}
