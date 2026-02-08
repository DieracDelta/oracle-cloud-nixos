# NixOS on Oracle Cloud Infrastructure

Deploy NixOS to Oracle Cloud's **Always Free** tier with a single `terraform apply`.

## What You Get

By default, you get an **ARM instance** (recommended):

- **4 OCPUs** (ARM Ampere A1)
- **24 GB RAM**
- **100 GB boot volume** (configurable up to 200 GB free)

Alternatively, you can deploy an **x86 micro instance** (very limited):

- **1 OCPU** (AMD)
- **1 GB RAM**
- Up to 2 instances allowed

Both include:
- Vanilla NixOS with SSH access
- Automatic iSCSI boot support for OCI NATIVE mode

## Prerequisites

- [Nix](https://nixos.org/download.html) with flakes enabled
- [Oracle Cloud account](https://www.oracle.com/cloud/free/) (free tier works!)
- [direnv](https://direnv.net/) (optional but recommended)

## Quick Start

```bash
git clone https://github.com/johnrichardrinehart/oracle-cloud-nixos
cd oracle-cloud-nixos
cp .env.example .env
# Edit .env with your OCI credentials (see below)
direnv allow  # or: nix develop
terraform init
terraform apply
```

## Getting Oracle Cloud Credentials

1. **Create an OCI account** at https://www.oracle.com/cloud/free/

2. **Get your Tenancy OCID**:
   - OCI Console → Profile (top right) → Tenancy: `<your-tenancy>`
   - Copy the OCID (starts with `ocid1.tenancy.oc1..`)

3. **Get your User OCID**:
   - OCI Console → Profile → User Settings
   - Copy your OCID (starts with `ocid1.user.oc1..`)

4. **Generate an API Key**:
   ```bash
   # Generate private key
   mkdir -p ~/.oci
   openssl genrsa -out ~/.oci/oci_api_key.pem 2048
   chmod 600 ~/.oci/oci_api_key.pem

   # Generate public key
   openssl rsa -pubout -in ~/.oci/oci_api_key.pem -out ~/.oci/oci_api_key_public.pem
   ```

5. **Upload the public key to OCI**:
   - OCI Console → Profile → User Settings → API Keys → Add API Key
   - Choose "Paste Public Key" and paste contents of `~/.oci/oci_api_key_public.pem`
   - Copy the fingerprint shown

6. **Choose a region**:
   - Check available regions at: OCI Console → Administration → Regions
   - Common regions: `us-ashburn-1`, `us-phoenix-1`, `eu-frankfurt-1`

7. **Fill in your `.env` file**:
   ```bash
   TF_VAR_oci_tenancy_ocid="ocid1.tenancy.oc1..aaaa..."
   TF_VAR_oci_user_ocid="ocid1.user.oc1..aaaa..."
   TF_VAR_oci_fingerprint="xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx"
   TF_VAR_oci_region="us-ashburn-1"
   TF_VAR_oci_private_key_path="/home/YOUR_USER/.oci/oci_api_key.pem"
   TF_VAR_ssh_public_key="ssh-ed25519 AAAA..."
   ```

## Customizing the NixOS Configuration

The base image is defined in `flake.nix`. To customize:

```nix
# In flake.nix, find the oci-base-image package and modify:
({ config, lib, pkgs, ... }: {
  system.stateVersion = "25.11";
  networking.hostName = "my-custom-hostname";

  # Add packages
  environment.systemPackages = with pkgs; [
    vim
    git
    htop
    # Add your packages here
  ];

  # Enable services
  services.nginx.enable = true;

  # Configure firewall (add ports in terraform/network.tf too!)
  networking.firewall.allowedTCPPorts = [ 80 443 ];
})
```

After modifying, run `terraform apply` to rebuild and redeploy.

## Configuration Options

Set these in your `.env` file or pass to terraform:

| Variable | Default | Description |
|----------|---------|-------------|
| `TF_VAR_instance_arch` | `arm` | Architecture: `arm` (4 OCPU, 24GB) or `x86` (1 OCPU, 1GB micro) |
| `TF_VAR_instance_name` | `nixos-oci` | Instance display name |
| `TF_VAR_instance_ocpus` | `4` | Number of OCPUs (ARM only, ignored for x86) |
| `TF_VAR_instance_memory_gb` | `24` | Memory in GB (ARM only, ignored for x86) |
| `TF_VAR_boot_volume_gb` | `100` | Boot volume size (max 200 free) |
| `TF_VAR_delete_image_after_instance` | `false` | Delete staging bucket after image import |

### Using x86 instead of ARM

To deploy an x86 micro instance instead of ARM:

```bash
# In .env:
TF_VAR_instance_arch="x86"

# Or via command line:
TF_VAR_instance_arch=x86 terraform apply
```

Note: x86 micro instances are very limited (1 OCPU, 1GB RAM). ARM is recommended for most workloads.

## Verification & Troubleshooting

### SSH Access

After `terraform apply` completes:

```bash
# Use the output SSH command
terraform output ssh_command
# Or manually:
ssh root@<instance-public-ip>
```

### Serial Console (for boot issues)

If SSH doesn't work, use the serial console to debug boot issues:

1. OCI Console → Compute → Instances → Click your instance
2. Resources (left sidebar) → Console connection
3. Click "Launch Cloud Shell connection"

This gives you direct console access even before the network is up.

### Common Issues

**Instance stuck in "PROVISIONING"**:
- Free tier ARM instances are in high demand
- Try a different availability domain or region
- Wait and retry - OCI queues requests

**SSH connection refused**:
- Wait a few minutes for boot to complete
- Check security list has port 22 open (it should by default)
- Use serial console to check boot status

**iSCSI boot failures (in serial console)**:
- Check that the instance is using "NATIVE" launch mode
- Verify network is coming up in initrd
- The `boot.shell_on_fail` kernel param will drop you to a shell on failure

## LVM Storage Setup

When `enable_block_volume = true` (default), the system uses LVM to combine:
- Boot volume partition 3 (~95GB)
- Block volume (100GB)

Into a single ~195GB btrfs volume with subvolumes for `/nix` and `/home`.

### How It Works

1. **First boot**: System boots with `/nix` on the boot volume (~3GB)
2. **`first-boot-lvm` service**: Creates LVM, btrfs, rsyncs `/nix` to LVM
3. **Terraform provisioning**: Generates `lvm-mounts.nix` with `fileSystems` declarations
4. **`nixos-rebuild boot`**: Builds new generation with LVM mount config
5. **rsync**: Copies new `/nix` to LVM volume
6. **Reboot**: Initrd mounts `/nix` from LVM, shadowing the boot volume's `/nix`

After this, the boot volume's `/nix` (~3GB) is never used - it's shadowed by the LVM mount.

### Emergency Recovery (Block Volume Unavailable)

If the block volume is damaged or unavailable, you can boot from the boot volume's original `/nix` store. This contains a snapshot of the system from initial provisioning.

**Prerequisites**: Enable initrd SSH in your config:
```nix
oci.hardware.initrdSSH = {
  enable = true;
  authorizedKeys = [ "ssh-ed25519 AAAA..." ];
};
```

**Recovery procedure**:

1. At GRUB menu, press `e` to edit the boot entry

2. Find the `linux` line and append:
   ```
   systemd.mask=nix.mount systemd.mask=nix-store.mount
   ```
   This tells systemd to skip mounting `/nix` from LVM, using the boot volume's `/nix` instead.

3. Press `Ctrl+X` or `F10` to boot

4. The system boots using the boot volume's original `/nix` store. You can now debug/repair LVM or reconfigure without it.

**Alternative - from initrd shell**:

If already in initrd emergency shell:
```bash
# Mount root filesystem
mkdir -p /mnt-root
mount /dev/sdb2 /mnt-root

# Mask the LVM mount units so stage-2 doesn't try to mount them
ln -sf /dev/null /mnt-root/etc/systemd/system/nix.mount
ln -sf /dev/null /mnt-root/etc/systemd/system/nix-store.mount

# Continue boot with smol boi /nix
exec switch_root /mnt-root /nix/store/*-nixos-system-*/init
```

**Note**: The boot volume's `/nix` is a snapshot from initial terraform provisioning. Any `nixos-rebuild` commands run after that only update the LVM volume. The recovery system will be the original configuration, not your current one.

## Image Management

NixOS images are cached by their nix store hash. This means:
- Identical configurations reuse existing images (fast!)
- Configuration changes create new images

### Storage Warning

Each image is ~1-2 GiB. OCI free tier includes ~10 GiB object storage.
Multiple images may exceed the free tier and incur charges.

To clean up old images:
```bash
nix run .#cleanup-images
```

To automatically delete staging files after upload:
```bash
# In .env or terraform command:
TF_VAR_delete_image_after_instance=true terraform apply
```

## Security Notes

By default, only SSH (port 22) and ICMP are allowed inbound.

To add more ports, edit `terraform/network.tf`:

```hcl
# Example: Allow HTTPS
ingress_security_rules {
  protocol  = "6" # TCP
  source    = "0.0.0.0/0"
  stateless = false
  tcp_options {
    min = 443
    max = 443
  }
}
```

## Using the Hardware Module in Your Own Flake

This repo exports a NixOS module for OCI ARM hardware support:

```nix
{
  inputs.oracle-cloud-nixos.url = "github:johnrichardrinehart/oracle-cloud-nixos";

  outputs = { self, nixpkgs, oracle-cloud-nixos, ... }: {
    nixosConfigurations.my-oci-server = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        oracle-cloud-nixos.nixosModules.oci-hardware
        # Your configuration here
      ];
    };
  };
}
```

## License

MIT
