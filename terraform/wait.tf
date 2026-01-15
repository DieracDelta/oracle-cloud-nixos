# Wait for instance to fully boot
# This ensures terraform completes only when the instance is actually usable
resource "null_resource" "wait_for_boot" {
  depends_on = [oci_core_instance.nixos]

  triggers = {
    instance_id = oci_core_instance.nixos.id
  }

  connection {
    type        = "ssh"
    host        = oci_core_instance.nixos.public_ip
    user        = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  # Wait for NixOS to be fully booted
  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for NixOS to be ready...'",
      "while [ ! -f /etc/NIXOS ]; do sleep 5; done",
      "echo 'NixOS is ready!'",
      "uname -a",
      "nixos-version"
    ]
  }
}
