output "vcn_id" {
  description = "OCID of the VCN"
  value       = oci_core_vcn.main.id
}

output "public_subnet_id" {
  description = "OCID of the public subnet"
  value       = oci_core_subnet.public.id
}

output "private_subnet_id" {
  description = "OCID of the private subnet"
  value       = oci_core_subnet.private.id
}

output "public_security_list_id" {
  description = "OCID of the public security list"
  value       = oci_core_security_list.public.id
}

output "private_security_list_id" {
  description = "OCID of the private security list"
  value       = oci_core_security_list.private.id
}

output "headscale_nsg_id" {
  description = "OCID of the headscale network security group"
  value       = oci_core_network_security_group.headscale.id
}

output "internet_gateway_id" {
  description = "OCID of the internet gateway"
  value       = oci_core_internet_gateway.main.id
}

output "nat_gateway_id" {
  description = "OCID of the NAT gateway"
  value       = oci_core_nat_gateway.main.id
}

output "availability_domains" {
  description = "List of availability domains"
  value       = data.oci_identity_availability_domains.ads.availability_domains[*].name
}
