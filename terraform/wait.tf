# Wait for instances to fully boot
# This ensures terraform completes only when all instances are actually usable
resource "null_resource" "wait_for_boot" {
  for_each = var.instances

  depends_on = [oci_core_instance.nixos]

  triggers = {
    instance_id = oci_core_instance.nixos[each.key].id
  }

  connection {
    type        = "ssh"
    host        = oci_core_instance.nixos[each.key].public_ip
    user        = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  # Wait for NixOS to be fully booted
  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for NixOS ${each.key} to be ready...'",
      "while [ ! -f /etc/NIXOS ]; do sleep 5; done",
      "echo 'NixOS ${each.key} is ready!'",
      "uname -a",
      "nixos-version"
    ]
  }
}
