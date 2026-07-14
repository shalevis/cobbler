#!/usr/bin/env bash
#
# 3-configure-cobbler.sh
# RUN THIS ON THE OFFLINE Cobbler server, as root, after 2-install-offline.sh.
#
# For each Ubuntu release it:
#   1. Publishes the ISO + local .deb repo over HTTP
#   2. Imports the distro into Cobbler and creates a profile
#   3. Renders the autoinstall (usbguard/IPA/ansible/local-admin) from the template
#   4. Points the profile at the autoinstall via NoCloud kernel args

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/config/cobbler.env"

if [[ $EUID -ne 0 ]]; then echo "Run as root: sudo $0" >&2; exit 1; fi

WWW="/var/www/html"
HASH_FILE="$ROOT/config/localadmin.hash"
PUBKEY_FILE="$ROOT/config/ansible_id_ed25519.pub"

[[ -f "$HASH_FILE" ]]   || { echo "Missing $HASH_FILE — run 2-install-offline.sh first." >&2; exit 1; }
[[ -f "$PUBKEY_FILE" ]] || { echo "Missing $PUBKEY_FILE — run 2-install-offline.sh first." >&2; exit 1; }

LOCALADMIN_HASH="$(cat "$HASH_FILE")"
ANSIBLE_PUBKEY="$(cat "$PUBKEY_FILE")"

# Secrets prompted at install (root-only). Empty if the feature is disabled.
IPA_PASSWORD="$(cat "$ROOT/config/ipa_join.secret" 2>/dev/null || echo "")"
CIFS_PASSWORD="$(cat "$ROOT/config/cifs.secret" 2>/dev/null || echo "")"

# Publish CA certs once (shared across releases), if provided.
mkdir -p "$WWW/pituah/certs"
for c in $CA_CERTS; do
  [[ -f "$ROOT/certs/$c" ]] && cp -f "$ROOT/certs/$c" "$WWW/pituah/certs/$c"
done

# Escape a value for safe use as sed replacement text (handles \ & |).
esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# release label|codename|iso pairs
process_release() {
  local label="$1" code="$2" iso="$ROOT/isos/$3"
  echo "=============================================================="
  echo " Release: $label ($code)"
  echo "=============================================================="

  [[ -f "$iso" ]] || { echo "  ISO not found: $iso — skipping"; return 0; }

  # 1) Decide the package source for this release and write provision-sources.list.
  local prov="$WWW/pituah/$code"
  mkdir -p "$prov"
  if [[ "${PKG_SOURCE:-localdebs}" == "localdebs" ]]; then
    echo "  package source: bundled local .deb repo (served over HTTP)"
    mkdir -p "$WWW/localdebs/$code"
    cp -f "$ROOT/localdebs/$code/localdebs.tar.gz" "$WWW/localdebs/$code/"
    tar -xzf "$ROOT/localdebs/$code/localdebs.tar.gz" -C "$WWW/localdebs/$code/" 2>/dev/null || true
    printf 'deb [trusted=yes] http://%s/localdebs/%s/ ./\n' "$COBBLER_SERVER_IP" "$code" \
      > "$prov/provision-sources.list"
  else
    echo "  package source: your existing offline archive mirror"
    printf '%s\n' "$ARCHIVE_APT_LINES" | sed "s/{RELEASE}/$code/g" \
      > "$prov/provision-sources.list"
  fi

  # 2) Publish the ISO and import it into Cobbler.
  mkdir -p "$WWW/isos"
  cp -f "$iso" "$WWW/isos/$label.iso"
  local mnt="/mnt/$label"
  mkdir -p "$mnt"
  mount -o loop,ro "$iso" "$mnt" 2>/dev/null || true
  cobbler import --name="$label" --path="$mnt" --arch=x86_64 \
    --breed=ubuntu --os-version="$code" 2>/dev/null || \
    echo "  (import may already exist; continuing)"

  # 3) Render the autoinstall template for this release.
  local auto_dir="$WWW/autoinstall/$label"
  mkdir -p "$auto_dir"
  sed -e "s|__COBBLER_SERVER_IP__|$COBBLER_SERVER_IP|g" \
      -e "s|__RELEASE__|$code|g" \
      -e "s|__HOSTNAME__|ubuntu-host|g" \
      -e "s|__LOCALADMIN_USER__|$LOCALADMIN_USER|g" \
      -e "s|__LOCALADMIN_HASH__|$LOCALADMIN_HASH|g" \
      -e "s|__ANSIBLE_USER__|$ANSIBLE_USER|g" \
      -e "s|__ANSIBLE_PUBKEY__|$ANSIBLE_PUBKEY|g" \
      -e "s|__IPA_DOMAIN__|$IPA_DOMAIN|g" \
      -e "s|__IPA_REALM__|$IPA_REALM|g" \
      -e "s|__IPA_SERVER__|$IPA_SERVER|g" \
      -e "s|__IPA_OTP__|REPLACE_WITH_OTP|g" \
      "$ROOT/autoinstall/ubuntu.user-data.tmpl" > "$auto_dir/user-data"
  sed -e "s|__INSTANCE_ID__|$label-base|g" \
      "$ROOT/autoinstall/meta-data.tmpl" > "$auto_dir/meta-data"

  # 3b) Render + publish the pituah first-boot post-install job for this release.
  local pit_dir="$WWW/pituah/$code"
  mkdir -p "$pit_dir"
  sed -e "s|__COBBLER_SERVER_IP__|$(esc "$COBBLER_SERVER_IP")|g" \
      -e "s|__RELEASE__|$(esc "$code")|g" \
      -e "s|__IPA_DOMAIN__|$(esc "$IPA_DOMAIN")|g" \
      -e "s|__IPA_REALM__|$(esc "$IPA_REALM")|g" \
      -e "s|__IPA_SERVER__|$(esc "$IPA_SERVER")|g" \
      -e "s|__IPA_PRINCIPAL__|$(esc "$IPA_PRINCIPAL")|g" \
      -e "s|__IPA_PASSWORD__|$(esc "$IPA_PASSWORD")|g" \
      -e "s|__SECONDARY_DNS__|$(esc "$SECONDARY_DNS")|g" \
      -e "s|__NTP_SERVER__|$(esc "$NTP_SERVER")|g" \
      -e "s|__TIMEZONE__|$(esc "$TIMEZONE")|g" \
      -e "s|__ANSIBLE_USER__|$(esc "$ANSIBLE_USER")|g" \
      -e "s|__ANSIBLE_PUBKEY__|$(esc "$ANSIBLE_PUBKEY")|g" \
      -e "s|__CA_CERTS__|$(esc "$CA_CERTS")|g" \
      -e "s|__ENABLE_CIFS__|$(esc "$ENABLE_CIFS")|g" \
      -e "s|__CIFS_UNC__|$(esc "$CIFS_UNC")|g" \
      -e "s|__CIFS_MOUNTPOINT__|$(esc "$CIFS_MOUNTPOINT")|g" \
      -e "s|__CIFS_USER__|$(esc "$CIFS_USER")|g" \
      -e "s|__CIFS_PASSWORD__|$(esc "$CIFS_PASSWORD")|g" \
      -e "s|__ENABLE_TRELLIX__|$(esc "$ENABLE_TRELLIX")|g" \
      -e "s|__TRELLIX_SCRIPT__|$(esc "$TRELLIX_SCRIPT")|g" \
      "$ROOT/autoinstall/pituah-postinstall.sh.tmpl" > "$pit_dir/pituah-postinstall.sh"
  chmod 0644 "$pit_dir/pituah-postinstall.sh"

  # 4) Point the profile at the ISO + NoCloud autoinstall via kernel args.
  local ks_url="http://$COBBLER_SERVER_IP/autoinstall/$label/"
  local iso_url="http://$COBBLER_SERVER_IP/isos/$label.iso"
  cobbler profile edit --name="${label}-x86_64" \
    --kernel-options="ip=dhcp url=$iso_url autoinstall ds=nocloud-net;s=$ks_url" \
    2>/dev/null || \
  cobbler profile edit --name="$label" \
    --kernel-options="ip=dhcp url=$iso_url autoinstall ds=nocloud-net;s=$ks_url" \
    2>/dev/null || echo "  (set kernel options manually if the profile name differs)"

  umount "$mnt" 2>/dev/null || true
  echo "  base autoinstall: $auto_dir/user-data  (OTP is per-host; use new-host.sh)"
}

process_release "$UBUNTU_2204_LABEL"  "$UBUNTU_2204_CODENAME"  "$UBUNTU_2204_LABEL.iso"
process_release "$UBUNTU_NOBLE_LABEL" "$UBUNTU_NOBLE_CODENAME" "$UBUNTU_NOBLE_LABEL.iso"

cobbler sync 2>/dev/null || true

cat <<EOF

============================================================
Configuration complete.

VERIFY:
  cobbler profile list
  cobbler distro list

PER-MACHINE DEPLOY (creates OTP + per-host autoinstall):
  ./scripts/new-host.sh <fqdn> <${UBUNTU_2204_LABEL}|${UBUNTU_NOBLE_LABEL}> [MAC]

Point your EXISTING DHCP at this server:
  next-server $COBBLER_SERVER_IP
  filename    "pxelinux.0"        (BIOS)
  filename    "grub/grubx64.efi"  (UEFI)
============================================================
EOF
