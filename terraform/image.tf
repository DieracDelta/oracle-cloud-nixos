# Build generic NixOS OCI base image
#
# We use nix eval to get the output path instantly without building.
# The actual build only happens if the path doesn't exist in the store.
# This makes terraform plan fast even when the image needs rebuilding.
#
# We tag OCI images with the nix store hash so we can skip upload if
# an image for this exact derivation already exists in OCI.

locals {
  # Map instance_arch to nix system and OCI shape
  nix_system  = var.instance_arch == "arm" ? "aarch64-linux" : "x86_64-linux"
  shape_name  = var.instance_arch == "arm" ? "VM.Standard.A1.Flex" : "VM.Standard.E2.1.Micro"
  is_flexible = var.instance_arch == "arm" # Only ARM shape is flexible (configurable OCPU/RAM)
}

data "external" "image_path" {
  program = ["bash", "-c", <<-EOF
    SYSTEM="${local.nix_system}"
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
      nix build .#packages.$SYSTEM.oci-base-image -o result-oci-image >&2
      IMAGE_PATH=$(cut -d' ' -f3 result-oci-image/nix-support/hydra-build-products)
    fi
    echo "{\"path\": \"$IMAGE_PATH\", \"nix_hash\": \"$NIX_HASH\", \"arch\": \"${var.instance_arch}\"}"
  EOF
  ]
  working_dir = "${path.module}/.."
}

locals {
  image_path = data.external.image_path.result.path
  nix_hash   = data.external.image_path.result.nix_hash
  image_arch = data.external.image_path.result.arch
}

# Check if an OCI image with this nix hash already exists
data "oci_core_images" "existing_for_hash" {
  compartment_id = local.compartment_id
  state          = "AVAILABLE"

  filter {
    name   = "freeform_tags.nix_hash"
    values = [local.nix_hash]
  }

  filter {
    name   = "freeform_tags.arch"
    values = [local.image_arch]
  }
}

locals {
  # Use existing image if found, otherwise we'll create one
  existing_image_id = length(data.oci_core_images.existing_for_hash.images) > 0 ? data.oci_core_images.existing_for_hash.images[0].id : null
  need_upload       = local.existing_image_id == null
}

data "oci_objectstorage_namespace" "ns" {
  compartment_id = local.compartment_id
}

# Object Storage bucket for image upload (only needed if uploading)
resource "oci_objectstorage_bucket" "image_upload" {
  count          = local.need_upload ? 1 : 0
  compartment_id = local.compartment_id
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "nixos-oci-image-${local.image_arch}-${local.nix_hash}"
  access_type    = "NoPublicAccess"
}

# Upload the image to Object Storage (only if no existing image)
resource "oci_objectstorage_object" "nixos_image" {
  count        = local.need_upload ? 1 : 0
  namespace    = data.oci_objectstorage_namespace.ns.namespace
  bucket       = oci_objectstorage_bucket.image_upload[0].name
  object       = "nixos-base-${local.image_arch}-${local.nix_hash}.qcow2"
  source       = local.image_path
  content_type = "application/octet-stream"
}

# Create custom image from the uploaded qcow2 (only if no existing image)
resource "oci_core_image" "nixos" {
  count          = local.need_upload ? 1 : 0
  compartment_id = local.compartment_id
  display_name   = "nixos-base-${local.image_arch}-${local.nix_hash}"
  launch_mode    = "NATIVE"

  freeform_tags = {
    nix_hash = local.nix_hash
    arch     = local.image_arch
  }

  image_source_details {
    source_type    = "objectStorageTuple"
    namespace_name = data.oci_objectstorage_namespace.ns.namespace
    bucket_name    = oci_objectstorage_bucket.image_upload[0].name
    object_name    = oci_objectstorage_object.nixos_image[0].object

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
  count          = local.need_upload ? 1 : 0
  compartment_id = local.compartment_id
  image_id       = oci_core_image.nixos[0].id
  shape_name     = local.shape_name
}

# The image ID to use - either existing or newly created
locals {
  image_id = local.existing_image_id != null ? local.existing_image_id : oci_core_image.nixos[0].id
}

# Optional: Delete staging bucket/object after image creation to save storage
# This runs after the image is successfully imported
resource "null_resource" "cleanup_staging" {
  count = var.delete_image_after_instance && local.need_upload ? 1 : 0

  depends_on = [
    oci_core_image.nixos,
    oci_core_shape_management.nixos,
  ]

  triggers = {
    bucket_name = oci_objectstorage_bucket.image_upload[0].name
    namespace   = data.oci_objectstorage_namespace.ns.namespace
    object_name = oci_objectstorage_object.nixos_image[0].object
  }

  provisioner "local-exec" {
    command = <<-EOF
      echo "Cleaning up staging bucket and object to save storage..."

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
        --bucket-name "${oci_objectstorage_bucket.image_upload[0].name}" \
        --object-name "${oci_objectstorage_object.nixos_image[0].object}" \
        --force || echo "Warning: Failed to delete object (may already be deleted)"

      # Delete the bucket
      oci os bucket delete \
        --config-file "$OCI_CONFIG" \
        --namespace "${data.oci_objectstorage_namespace.ns.namespace}" \
        --bucket-name "${oci_objectstorage_bucket.image_upload[0].name}" \
        --force || echo "Warning: Failed to delete bucket (may already be deleted)"

      echo "Staging cleanup complete"
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
