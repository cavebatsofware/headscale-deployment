# =============================================================================
# OCI Vault Module Variables
# =============================================================================

variable "compartment_ocid" {
  description = "OCI compartment OCID"
  type        = string
}

variable "tenancy_ocid" {
  description = "OCI tenancy OCID (required for IAM policies)"
  type        = string
}

variable "project" {
  description = "Project name for resource tagging"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}
