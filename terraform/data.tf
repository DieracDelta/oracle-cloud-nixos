locals {
  # Default compartment_id to tenancy OCID if not specified
  compartment_id      = coalesce(var.compartment_id, var.oci_tenancy_ocid)
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
}

# Find availability domains
data "oci_identity_availability_domains" "ads" {
  compartment_id = local.compartment_id
}

# Debug: list compatible shapes for our custom image
data "oci_core_image_shapes" "nixos_shapes" {
  image_id = local.image_id
}
