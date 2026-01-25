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

# Complete LVM setup after block volume is attached
# This waits for the first-boot-lvm service to finish, then configures mounts
resource "null_resource" "setup_lvm" {
  count = var.enable_block_volume ? 1 : 0

  depends_on = [
    null_resource.wait_for_boot,
    oci_core_volume_attachment.data
  ]

  triggers = {
    instance_id = oci_core_instance.nixos["nixos-arm"].id
    volume_id   = oci_core_volume.data[0].id
  }

  connection {
    type        = "ssh"
    host        = oci_core_instance.nixos["nixos-arm"].public_ip
    user        = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "15m"
  }

  # Copy oci-hardware.nix module for proper device initialization in initrd
  provisioner "file" {
    source      = "${path.module}/../modules/oci-hardware.nix"
    destination = "/etc/nixos/oci-hardware.nix"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '=== Waiting for first-boot LVM setup to complete ==='",
      "for i in $(seq 1 300); do if [ -f /var/lib/first-boot-lvm-done ]; then echo 'First-boot LVM setup completed!'; break; fi; if systemctl is-failed first-boot-lvm.service 2>/dev/null; then echo 'ERROR: first-boot-lvm service failed'; journalctl -u first-boot-lvm.service --no-pager; exit 1; fi; echo \"Waiting for LVM setup... ($i/300)\"; sleep 10; done",
      "if ! vgs datavg &>/dev/null; then echo 'ERROR: Volume group datavg not found'; exit 1; fi",
      "echo '=== LVM status ==='; vgs; lvs",
      "echo '=== Creating NixOS configuration for LVM mounts ==='",
      "cat > /etc/nixos/lvm-mounts.nix << 'EOFNIX'\n{ config, lib, pkgs, ... }:\n{\n  # LVM activation in preLVMCommands (runs after oci-hardware.nix device settling)\n  boot.initrd.preLVMCommands = lib.mkAfter ''\n    echo \"Activating LVM volume groups...\"\n    lvm vgscan --mknodes\n    lvm vgchange -ay\n    lvm lvscan\n    sleep 1\n  '';\n\n  # Mount /nix and /home from LVM btrfs volume\n  fileSystems.\"/nix\" = {\n    device = \"/dev/datavg/datalv\";\n    fsType = \"btrfs\";\n    options = [ \"subvol=@nix\" \"compress=zstd\" \"noatime\" ];\n  };\n  fileSystems.\"/home\" = {\n    device = \"/dev/datavg/datalv\";\n    fsType = \"btrfs\";\n    options = [ \"subvol=@home\" \"compress=zstd\" \"noatime\" ];\n  };\n}\nEOFNIX",
      "cat > /etc/nixos/configuration.nix << 'EOFCFG'\n{ modulesPath, ... }:\n{\n  imports = [\n    \"$${modulesPath}/virtualisation/oci-common.nix\"\n    ./oci-hardware.nix\n    ./lvm-mounts.nix\n  ];\n  # Enable LVM support in oci-hardware module (adds kernel modules, tools, device settling)\n  oci.hardware.enableLVM = true;\n}\nEOFCFG",
      "echo '=== Setting up nix channel ==='",
      "nix-channel --add https://nixos.org/channels/nixos-unstable nixos",
      "nix-channel --update",
      "echo '=== Running nixos-rebuild boot (not switch - unsafe to live-mount /nix) ==='",
      "export NIX_PATH=nixos-config=/etc/nixos/configuration.nix:nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos && nixos-rebuild boot 2>&1 | tail -100",
      "echo '=== Syncing new store paths to LVM volume ==='",
      "MOUNT_POINT=$(mktemp -d) && mount /dev/datavg/datalv -o subvol=@nix $MOUNT_POINT && rsync -aAX --delete /nix/ $MOUNT_POINT/ && umount $MOUNT_POINT && rmdir $MOUNT_POINT",
      "echo '=== Rebooting to activate new mounts ==='",
      "shutdown -r +0 'Rebooting to activate LVM mounts' || reboot"
    ]
  }
}
