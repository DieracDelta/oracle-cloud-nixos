output "instance_public_ip" {
  description = "Public IP address of the NixOS instance"
  value       = oci_core_instance.nixos.public_ip
}

output "instance_private_ip" {
  description = "Private IP address of the NixOS instance"
  value       = oci_core_instance.nixos.private_ip
}

output "instance_id" {
  description = "OCID of the NixOS instance"
  value       = oci_core_instance.nixos.id
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh root@${oci_core_instance.nixos.public_ip}"
}

output "image_id" {
  description = "The OCI image ID being used (existing or newly created)"
  value       = local.image_id
}

output "image_reused" {
  description = "Whether an existing image was reused"
  value       = local.existing_image_id != null
}

output "old_images_to_delete" {
  description = "Image IDs that should be deleted (run: nix run .#cleanup-images)"
  value       = local.old_image_ids
}

output "debug_compatible_shapes" {
  description = "Compatible instance shapes for the NixOS image"
  value       = data.oci_core_image_shapes.nixos_shapes.image_shape_compatibilities[*].shape
}

# Storage warning for users
output "storage_warning" {
  description = "Important: Check your OCI object storage usage"
  value       = <<-EOT
    NOTE: Each NixOS image is ~1-2 GiB. OCI free tier includes ~10 GiB of object storage.
    Multiple images may exceed the free tier and incur charges.

    Current images in your account: ${length(local.all_existing_ids)}
    Images to clean up: ${local.excess_image_count}

    To clean up old images: nix run .#cleanup-images
    To auto-delete staging after upload: set delete_image_after_instance = true
  EOT
}
