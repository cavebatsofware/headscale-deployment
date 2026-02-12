variable "compartment_ocid" {
  description = "OCID of the compartment"
  type        = string
}

variable "vcn_cidr_block" {
  description = "CIDR block for the VCN"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet"
  type        = string
  default     = "10.0.2.0/24"
}

variable "project" {
  description = "Project name for resource tagging"
  type        = string
}

variable "vcn_dns_label" {
  description = "DNS label for the VCN (max 15 alphanumeric characters, no hyphens)"
  type        = string
  default     = "headscale"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9]{0,14}$", var.vcn_dns_label))
    error_message = "VCN DNS label must start with a letter, contain only alphanumeric characters, and be 1-15 characters long."
  }
}

variable "environment" {
  description = "Environment name"
  type        = string
}
