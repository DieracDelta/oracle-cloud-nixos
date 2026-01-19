# Build generic NixOS OCI base images for all required architectures
#
# We use nix eval to get the output path instantly without building.
# The actual build only happens if the path doesn't exist in the store.
# This makes terraform plan fast even when images need rebuilding.
#
# We tag OCI images with the nix store hash so we can skip upload if
# an image for this exact derivation already exists in OCI.

locals {
  # Get unique architectures needed from all instances
  required_archs = toset([for name, config in var.instances : config.arch])

  # Map arch to nix system
  arch_to_nix_system = {
    "arm" = "aarch64-linux"
    "x86" = "x86_64-linux"
  }

  # Map arch to OCI shape
  arch_to_shape = {
    "arm" = "VM.Standard.A1.Flex"
    "x86" = "VM.Standard.E2.1.Micro"
  }
}

data "external" "image_path" {
  for_each = local.required_archs

  program = ["bash", "-c", <<-EOF
    SYSTEM="${local.arch_to_nix_system[each.key]}"
    # Get the derivation's output path without building
    DRV_PATH=$(nix eval .#packages.$SYSTEM.oci-base-image.outPath --raw)
    # Extract just the hash portion for tagging (e.g., "abc123-nixos-oci-image")
    NIX_HASH=$(basename "$DRV_PATH" | cut -d'-' -f1)
    # The actual qcow2 is inside the output, referenced in hydra-build-products
    # We need to build to get the final image path, but only if not cached
    if [ -e "$DRV_PATH" ]; then
      IMAGE_PATH=$(cut -d' ' -f3 "$DRV_PATH/nix-support/hydra-build-products")
    else
      # Not built yet - build it now
      nix build .#packages.$SYSTEM.oci-base-image -o result-oci-image-${each.key} >&2
      IMAGE_PATH=$(cut -d' ' -f3 result-oci-image-${each.key}/nix-support/hydra-build-products)
    fi
    echo "{\"path\": \"$IMAGE_PATH\", \"nix_hash\": \"$NIX_HASH\", \"arch\": \"${each.key}\"}"
  EOF
  ]
  working_dir = "${path.module}/.."
}

locals {
  # Map of arch -> image details
  image_details = {
    for arch in local.required_archs : arch => {
      path     = data.external.image_path[arch].result.path
      nix_hash = data.external.image_path[arch].result.nix_hash
    }
  }
}

# Check if an OCI image with this nix hash already exists (per arch)
data "oci_core_images" "existing_for_hash" {
  for_each       = local.required_archs
  compartment_id = local.compartment_id
  state          = "AVAILABLE"

  filter {
    name   = "freeform_tags.nix_hash"
    values = [local.image_details[each.key].nix_hash]
  }

  filter {
    name   = "freeform_tags.arch"
    values = [each.key]
  }
}

locals {
  # Map of arch -> existing image ID (or null)
  existing_image_ids = {
    for arch in local.required_archs :
    arch => length(data.oci_core_images.existing_for_hash[arch].images) > 0 ? data.oci_core_images.existing_for_hash[arch].images[0].id : null
  }

  # Which archs need upload
  archs_needing_upload = toset([
    for arch in local.required_archs : arch
    if local.existing_image_ids[arch] == null
  ])
}

data "oci_objectstorage_namespace" "ns" {
  compartment_id = local.compartment_id
}

# Object Storage bucket for image upload (only for archs that need it)
resource "oci_objectstorage_bucket" "image_upload" {
  for_each       = local.archs_needing_upload
  compartment_id = local.compartment_id
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "nixos-oci-image-${each.key}-${local.image_details[each.key].nix_hash}"
  access_type    = "NoPublicAccess"
}

# Upload the image to Object Storage (only for archs that need it)
resource "oci_objectstorage_object" "nixos_image" {
  for_each     = local.archs_needing_upload
  namespace    = data.oci_objectstorage_namespace.ns.namespace
  bucket       = oci_objectstorage_bucket.image_upload[each.key].name
  object       = "nixos-base-${each.key}-${local.image_details[each.key].nix_hash}.qcow2"
  source       = local.image_details[each.key].path
  content_type = "application/octet-stream"
}

# Create custom image from the uploaded qcow2 (only for archs that need it)
resource "oci_core_image" "nixos" {
  for_each       = local.archs_needing_upload
  compartment_id = local.compartment_id
  display_name   = "nixos-base-${each.key}-${local.image_details[each.key].nix_hash}"
  launch_mode    = "NATIVE"

  freeform_tags = {
    nix_hash = local.image_details[each.key].nix_hash
    arch     = each.key
  }

  image_source_details {
    source_type    = "objectStorageTuple"
    namespace_name = data.oci_objectstorage_namespace.ns.namespace
    bucket_name    = oci_objectstorage_bucket.image_upload[each.key].name
    object_name    = oci_objectstorage_object.nixos_image[each.key].object

    operating_system         = "NixOS"
    operating_system_version = "unstable"
    source_image_type        = "QCOW2"
  }

  timeouts {
    create = "30m"
  }
}

# Add shape compatibility to newly created images
resource "oci_core_shape_management" "nixos" {
  for_each       = local.archs_needing_upload
  compartment_id = local.compartment_id
  image_id       = oci_core_image.nixos[each.key].id
  shape_name     = local.arch_to_shape[each.key]
}

# Final image IDs map: arch -> image_id (existing or newly created)
locals {
  image_ids = {
    for arch in local.required_archs :
    arch => local.existing_image_ids[arch] != null ? local.existing_image_ids[arch] : oci_core_image.nixos[arch].id
  }
}

# Optional: Delete staging bucket/object after image creation to save storage
resource "null_resource" "cleanup_staging" {
  for_each = var.delete_image_after_instance ? local.archs_needing_upload : toset([])

  depends_on = [
    oci_core_image.nixos,
    oci_core_shape_management.nixos,
  ]

  triggers = {
    bucket_name = oci_objectstorage_bucket.image_upload[each.key].name
    namespace   = data.oci_objectstorage_namespace.ns.namespace
    object_name = oci_objectstorage_object.nixos_image[each.key].object
  }

  provisioner "local-exec" {
    command = <<-EOF
      echo "Cleaning up staging bucket and object for ${each.key} to save storage..."

      # Create temporary OCI config
      OCI_CONFIG=$(mktemp)
      trap 'rm -f "$OCI_CONFIG"' EXIT

      cat > "$OCI_CONFIG" << OCICONF
[DEFAULT]
tenancy=${var.oci_tenancy_ocid}
user=${var.oci_user_ocid}
fingerprint=${var.oci_fingerprint}
key_file=${var.oci_private_key_path}
region=${var.oci_region}
OCICONF

      # Delete the object
      oci os object delete \
        --config-file "$OCI_CONFIG" \
        --namespace "${data.oci_objectstorage_namespace.ns.namespace}" \
        --bucket-name "${oci_objectstorage_bucket.image_upload[each.key].name}" \
        --object-name "${oci_objectstorage_object.nixos_image[each.key].object}" \
        --force || echo "Warning: Failed to delete object (may already be deleted)"

      # Delete the bucket
      oci os bucket delete \
        --config-file "$OCI_CONFIG" \
        --namespace "${data.oci_objectstorage_namespace.ns.namespace}" \
        --bucket-name "${oci_objectstorage_bucket.image_upload[each.key].name}" \
        --force || echo "Warning: Failed to delete bucket (may already be deleted)"

      echo "Staging cleanup complete for ${each.key}"
    EOF
  }
}

# List all custom nixos-base images for cleanup tracking
data "oci_core_images" "nixos_all" {
  compartment_id = local.compartment_id
  state          = "AVAILABLE"

  filter {
    name   = "freeform_tags.nix_hash"
    values = ["*"]
    regex  = true
  }
}

locals {
  # All image IDs sorted by creation time (newest first)
  all_existing_ids = [for img in data.oci_core_images.nixos_all.images : img.id]
  # Number of images beyond the 3 we want to keep
  excess_image_count = length(local.all_existing_ids) > 3 ? length(local.all_existing_ids) - 3 : 0
  # IDs of images to delete (oldest ones)
  old_image_ids = length(local.all_existing_ids) > 3 ? slice(local.all_existing_ids, 3, length(local.all_existing_ids)) : []
}

# Check for old images and output warning
check "image_cleanup" {
  assert {
    condition     = local.excess_image_count == 0
    error_message = "WARNING: ${local.excess_image_count} old image(s) should be deleted. Run: nix run .#cleanup-images"
  }
}
