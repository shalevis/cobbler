#!/usr/bin/env bash
#
# 1-download-offline-bundle.sh
# RUN THIS ON AN INTERNET-CONNECTED Ubuntu machine (22.04/24.04), with sudo.
#
# Gathers everything needed to run Cobbler offline on Ubuntu and to deploy
# Ubuntu 22.04.1 + Noble with the full post-install (usbguard/IPA/ansible/admin):
#   1. Cobbler server deps  : apt .debs (system deps) + a pip wheelhouse for Cobbler
#   2. Per-release post-install packages: usbguard/freeipa-client/... via debootstrap
#   3. Ubuntu live-server ISOs (22.04.1 and Noble)
# Then packs it all into: cobbler-offline-bundle.tar.gz
#
# Requirements here: sudo, debootstrap, dpkg-dev, apt, python3-pip, curl/wget, tar.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/config/cobbler.env"

# snap/debootstrap/apt fail or misbehave on WSL's /mnt/c (drvfs); use a native dir.
WORKDIR="${WORKDIR:-$HOME/cobbler-offline-work}"
if [[ "$ROOT" == /mnt/* ]]; then
  echo "NOTE: repo is on a Windows drive ($ROOT)."
  echo "      Working in native path: $WORKDIR (debootstrap/apt need a real Linux fs)."
fi

SRV_DIR="$WORKDIR/cobbler-server"       # apt debs + pip wheelhouse for Cobbler itself
DEB_DIR="$WORKDIR/localdebs"            # per-release post-install package repos
ISO_DIR="$WORKDIR/isos"                # Ubuntu live-server ISOs
BUNDLE="$ROOT/cobbler-offline-bundle.tar.gz"

mkdir -p "$SRV_DIR/apt-debs" "$SRV_DIR/wheelhouse" "$DEB_DIR" "$ISO_DIR"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not installed. Run: sudo apt-get install -y $2" >&2; exit 1; }; }
need debootstrap debootstrap
need dpkg-scanpackages dpkg-dev
need pip3 python3-pip

# System dependencies Cobbler needs on the offline Ubuntu server come from
# $COBBLER_SYS_DEPS (defined in config/cobbler.env).

echo "=============================================================="
echo " STEP 1/4 — Cobbler SERVER: apt .debs + pip wheelhouse"
echo "=============================================================="
sudo apt-get update
if [[ "${COBBLER_DEPS_SOURCE:-bundle}" == "bundle" ]]; then
  echo "  - downloading Cobbler system-dependency .debs (with recursive deps)"
  # APT::Sandbox::User=root keeps apt from dropping to the '_apt' user, which
  # cannot read files under /root (the cause of the 'Permission denied' warnings).
  for pkg in $COBBLER_SYS_DEPS; do
    sudo apt-get install -y --download-only \
      -o APT::Sandbox::User=root \
      -o Dir::Cache::archives="$SRV_DIR/apt-debs" "$pkg" || \
      echo "    (warn) could not fully resolve $pkg"
  done
  sudo chown -R "$USER:$USER" "$SRV_DIR/apt-debs" 2>/dev/null || true
  ( cd "$SRV_DIR/apt-debs" && dpkg-scanpackages . /dev/null > Packages && gzip -kf Packages )
else
  echo "  - COBBLER_DEPS_SOURCE=$COBBLER_DEPS_SOURCE — system deps will come from"
  echo "    your archive mirror on the offline server; not bundling .debs."
fi

echo "  - building Cobbler pip wheelhouse (ALWAYS — not in any Ubuntu mirror)"
# Cobbler depends on the 'mod-wsgi' PyPI package, which COMPILES against Apache
# (needs apxs from apache2-dev). 'python-ldap' also compiles and needs the SASL +
# OpenLDAP + SSL dev headers. Install these here and BUILD wheels (pip wheel) so
# the offline server installs prebuilt wheels with no compiler/headers needed there.
sudo apt-get install -y apache2-dev libsasl2-dev libldap2-dev libssl-dev
pip3 wheel cobbler -w "$SRV_DIR/wheelhouse"

# The compiled wheels (mod_wsgi, python-ldap, Cheetah3) are ABI-specific to THIS
# Python. The offline server MUST run the same Python/Ubuntu release or pip will
# say "No matching distribution found for mod-wsgi". Assert + record the version.
python3 --version | tee "$SRV_DIR/wheelhouse/BUILD_PYTHON.txt"
for w in mod_wsgi python_ldap Cheetah3; do
  if ! ls "$SRV_DIR/wheelhouse/"*.whl 2>/dev/null | grep -qiE "${w//_/[-_]}"; then
    echo "  ERROR: compiled wheel for '$w' is MISSING from the wheelhouse." >&2
    echo "         The offline pip install will fail. Re-check the build above." >&2
    exit 1
  fi
done
echo "  - wheelhouse OK (mod_wsgi, python-ldap, Cheetah3 present; built for $(cat "$SRV_DIR/wheelhouse/BUILD_PYTHON.txt"))"

echo "=============================================================="
echo " STEP 2/4 — Per-release post-install package repos (debootstrap)"
echo "=============================================================="
if [[ "${PKG_SOURCE:-localdebs}" != "localdebs" ]]; then
  echo "  PKG_SOURCE=$PKG_SOURCE — using your existing offline apt mirror."
  echo "  Skipping debootstrap / local .deb repo build."
else
for code in $TARGET_CODENAMES; do
  echo "  --- $code ---"
  CHROOT="$WORKDIR/chroot-$code"
  OUT="$DEB_DIR/$code"
  mkdir -p "$OUT"

  if [[ ! -d "$CHROOT" ]]; then
    sudo debootstrap --variant=minbase --components=main,universe \
      "$code" "$CHROOT" http://archive.ubuntu.com/ubuntu
  fi

  # Ensure universe is enabled for usbguard/freeipa-client.
  echo "deb http://archive.ubuntu.com/ubuntu $code main universe" | \
    sudo tee "$CHROOT/etc/apt/sources.list" >/dev/null

  sudo chroot "$CHROOT" apt-get update
  # Download the post-install packages + their full dependency closure.
  sudo chroot "$CHROOT" bash -c \
    "apt-get install -y --download-only $POSTINSTALL_PACKAGES"

  # Collect the .debs and build a flat local apt repo (Packages index).
  sudo cp "$CHROOT"/var/cache/apt/archives/*.deb "$OUT"/ 2>/dev/null || true
  sudo chown -R "$USER:$USER" "$OUT"
  ( cd "$OUT" && dpkg-scanpackages . /dev/null > Packages && gzip -kf Packages )

  # Tar it so the autoinstall late-commands can fetch + extract one file.
  ( cd "$DEB_DIR" && tar -czf "$code/localdebs.tar.gz" -C "$code" \
      $(cd "$code" && ls | grep -vE '^localdebs.tar.gz$') )
  echo "    -> $OUT ($(ls "$OUT"/*.deb 2>/dev/null | wc -l) debs)"
done
fi

echo "=============================================================="
echo " STEP 3/4 — Download Ubuntu live-server ISOs"
echo "=============================================================="
fetch() { 

  if [[ -s "$2" ]]; then echo "    already present: $(basename "$2")"; return 0; fi 

  echo "    downloading $(basename "$2")" 

  wget -c --tries=15 --retry-connrefused --waitretry=5 -O "$2" "$1" 

}
fetch "$UBUNTU_2204_ISO_URL"  "$ISO_DIR/$UBUNTU_2204_LABEL.iso"
fetch "$UBUNTU_NOBLE_ISO_URL" "$ISO_DIR/$UBUNTU_NOBLE_LABEL.iso"

echo "=============================================================="
echo " STEP 4/4 — Assemble the transferable bundle"
echo "=============================================================="
# Copy the static repo files into the working dir so it all tars from one root.
cp -r "$ROOT/config" "$ROOT/autoinstall" "$ROOT/scripts" \
      "$ROOT/2-install-offline.sh" "$ROOT/3-configure-cobbler.sh" \
      "$ROOT/verify-bundle.sh" "$ROOT/README.md" "$WORKDIR/"
# CA certs for the pituah post-install (optional — create empty dir if absent).
mkdir -p "$WORKDIR/certs"
[[ -d "$ROOT/certs" ]] && cp -r "$ROOT/certs/." "$WORKDIR/certs/" 2>/dev/null || true

tar -C "$WORKDIR" -czf "$BUNDLE" \
  cobbler-server localdebs isos config autoinstall scripts certs \
  2-install-offline.sh 3-configure-cobbler.sh verify-bundle.sh README.md

echo
echo "DONE. Transfer this ONE file to the offline Cobbler server:"
echo "    $BUNDLE"
echo
echo "On the offline server:"
echo "    mkdir cobbler && tar -xzf cobbler-offline-bundle.tar.gz -C cobbler"
echo "    cd cobbler && sudo ./2-install-offline.sh"
