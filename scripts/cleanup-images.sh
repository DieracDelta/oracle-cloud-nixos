#!/usr/bin/env bash
# Cleanup old OCI custom images, keeping only the 3 most recent
# Uses TF_VAR_* environment variables for authentication
# Run with: nix run .#cleanup-images

# shellcheck disable=SC2154  # Variables come from environment

# Check required environment variables
: "${TF_VAR_oci_tenancy_ocid:?Error: TF_VAR_oci_tenancy_ocid not set. Source your .env file first.}"
: "${TF_VAR_oci_user_ocid:?Error: TF_VAR_oci_user_ocid not set. Source your .env file first.}"
: "${TF_VAR_oci_fingerprint:?Error: TF_VAR_oci_fingerprint not set. Source your .env file first.}"
: "${TF_VAR_oci_private_key_path:?Error: TF_VAR_oci_private_key_path not set. Source your .env file first.}"
: "${TF_VAR_oci_region:?Error: TF_VAR_oci_region not set. Source your .env file first.}"

COMPARTMENT_ID="${TF_VAR_oci_compartment_id:-$TF_VAR_oci_tenancy_ocid}"
KEEP_COUNT="${1:-3}"

# Create temporary OCI config
OCI_CONFIG=$(mktemp)
trap 'rm -f "$OCI_CONFIG"' EXIT

cat > "$OCI_CONFIG" << EOF
[DEFAULT]
tenancy=${TF_VAR_oci_tenancy_ocid}
user=${TF_VAR_oci_user_ocid}
fingerprint=${TF_VAR_oci_fingerprint}
key_file=${TF_VAR_oci_private_key_path}
region=${TF_VAR_oci_region}
EOF

echo "Listing NixOS images with nix_hash tag (keeping $KEEP_COUNT most recent)..."

# Get all images with nix_hash tag sorted by creation time (newest first)
images_json=$(oci compute image list \
  --config-file "$OCI_CONFIG" \
  --compartment-id "$COMPARTMENT_ID" \
  --lifecycle-state AVAILABLE \
  --sort-by TIMECREATED \
  --sort-order DESC \
  2>/dev/null || echo '{"data":[]}')

# Filter to only images with nix_hash tag
images_with_tag=$(echo "$images_json" | jq '[.data[] | select(.["freeform-tags"]["nix_hash"] != null)]')
image_ids=$(echo "$images_with_tag" | jq -r '.[].id' 2>/dev/null || echo "")
image_count=$(echo "$image_ids" | grep -c . || echo 0)

echo "Found $image_count NixOS image(s) with nix_hash tag"

if [[ $image_count -le $KEEP_COUNT ]]; then
  echo "No cleanup needed (have $image_count, keeping $KEEP_COUNT)"
  exit 0
fi

# Get IDs to delete (skip the first $KEEP_COUNT)
to_delete=$(echo "$image_ids" | tail -n +$((KEEP_COUNT + 1)))
delete_count=$(echo "$to_delete" | grep -c . || echo 0)

echo "Will delete $delete_count old image(s):"
echo "$to_delete" | while read -r id; do
  echo "  - $id"
done

# Confirm deletion
if [[ "${FORCE:-}" != "1" ]]; then
  read -p "Proceed with deletion? [y/N] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted"
    exit 1
  fi
fi

# Delete old images
echo "$to_delete" | while read -r id; do
  if [[ -n "$id" ]]; then
    echo "Deleting $id..."
    oci compute image delete \
      --config-file "$OCI_CONFIG" \
      --image-id "$id" \
      --force \
      2>/dev/null || echo "  Warning: Failed to delete $id"
  fi
done

echo "Cleanup complete"
