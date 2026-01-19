output "instances" {
  description = "Map of instance names to their details"
  value = {
    for name, instance in oci_core_instance.nixos : name => {
      id         = instance.id
      public_ip  = instance.public_ip
      private_ip = instance.private_ip
      arch       = var.instances[name].arch
      shape      = instance.shape
    }
  }
}

output "instance_public_ips" {
  description = "Map of instance names to public IPs"
  value = {
    for name, instance in oci_core_instance.nixos : name => instance.public_ip
  }
}

output "ssh_commands" {
  description = "SSH commands for all instances"
  value = {
    for name, instance in oci_core_instance.nixos : name => "ssh root@${instance.public_ip}"
  }
}

output "image_ids" {
  description = "Map of architecture to image ID being used"
  value       = local.image_ids
}

output "images_reused" {
  description = "Map of architecture to whether existing image was reused"
  value = {
    for arch in local.required_archs : arch => local.existing_image_ids[arch] != null
  }
}

output "old_images_to_delete" {
  description = "Image IDs that should be deleted (run: nix run .#cleanup-images)"
  value       = local.old_image_ids
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
