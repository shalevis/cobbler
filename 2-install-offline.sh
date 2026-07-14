#!/usr/bin/env bash
#
# 2-install-offline.sh
# RUN THIS ON THE OFFLINE Ubuntu Cobbler server, as root.
#
# Installs Cobbler from the bundled apt .debs + pip wheelhouse, enables the
# services, PROMPTS for the local admin password (stored only as a hash), and
# generates the ansible SSH keypair.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/config/cobbler.env"

if [[ $EUID -ne 0 ]]; then echo "Run as root: sudo $0" >&2; exit 1; fi

echo "=============================================================="
echo " STEP 1/5 — Install Cobbler system dependencies"
echo "=============================================================="
if [[ "${COBBLER_DEPS_SOURCE:-bundle}" == "archive" ]]; then
  echo "  - installing system deps from your archive mirror (apt)"
  echo "    (the server's apt must already point at your offline mirror)"
  apt-get update
  apt-get install -y $COBBLER_SYS_DEPS
else
  echo "  - installing system deps from the bundled .debs (offline)"
  # Install every bundled .deb; apt resolves order/deps from the local files.
  apt-get install -y --no-download "$ROOT"/cobbler-server/apt-debs/*.deb 2>/dev/null || \
    dpkg -i "$ROOT"/cobbler-server/apt-debs/*.deb || true
  # Second pass fixes any ordering issues using only local files (no network).
  dpkg -i "$ROOT"/cobbler-server/apt-debs/*.deb 2>/dev/null || true
fi

echo "=============================================================="
echo " STEP 2/5 — Install Cobbler from the pip wheelhouse (offline)"
echo "=============================================================="
pip3 install --no-index --find-links "$ROOT/cobbler-server/wheelhouse" cobbler
# Lay down Cobbler's config/service files.
cobblerd setup 2>/dev/null || true

echo "=============================================================="
echo " STEP 3/5 — Enable services (Apache proxy, TFTP, Cobbler)"
echo "=============================================================="
a2enmod proxy proxy_http rewrite 2>/dev/null || true
systemctl enable --now apache2 tftpd-hpa 2>/dev/null || true
# Cobbler ships cobblerd + gunicorn services via 'cobblerd setup'.
systemctl daemon-reload
systemctl enable --now cobblerd 2>/dev/null || true

# External DHCP/DNS: make sure Cobbler does NOT manage them.
SETTINGS="/etc/cobbler/settings.yaml"
if [[ -f "$SETTINGS" ]]; then
  sed -i \
    -e "s/^manage_dhcp:.*/manage_dhcp: 0/" \
    -e "s/^manage_dhcp_v4:.*/manage_dhcp_v4: 0/" \
    -e "s/^manage_dns:.*/manage_dns: 0/" \
    -e "s/^manage_tftpd:.*/manage_tftpd: 1/" \
    -e "s#^server:.*#server: $COBBLER_SERVER_IP#" \
    -e "s#^next_server_v4:.*#next_server_v4: $COBBLER_SERVER_IP#" \
    "$SETTINGS"
  systemctl restart cobblerd 2>/dev/null || true
fi
cobbler get-loaders 2>/dev/null || true
cobbler sync 2>/dev/null || true

echo "=============================================================="
echo " STEP 4/5 — Set the LOCAL ADMIN password (prompted, hashed)"
echo "=============================================================="
HASH_FILE="$ROOT/config/localadmin.hash"
if command -v mkpasswd >/dev/null 2>&1; then
  echo "Enter the password for local admin user '$LOCALADMIN_USER' (break-glass, root/sudo):"
  HASH="$(mkpasswd -m sha-512)"          # prompts securely, no echo
else
  # Fallback: openssl prompts, then hash with Python's crypt (SHA-512).
  read -rs -p "Enter password for local admin '$LOCALADMIN_USER': " PW; echo
  HASH="$(python3 -c 'import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))' "$PW")"
  unset PW
fi
umask 077
printf '%s\n' "$HASH" > "$HASH_FILE"
echo "  - stored SHA-512 hash in $HASH_FILE (no plaintext kept)"

# FreeIPA enrollment password (used by the pituah first-boot join). Stored
# root-only; it is injected into the published post-install script by step 3.
echo
read -rs -p "Enter FreeIPA enrollment password for principal '$IPA_PRINCIPAL': " IPA_PW; echo
printf '%s' "$IPA_PW" > "$ROOT/config/ipa_join.secret"
chmod 600 "$ROOT/config/ipa_join.secret"
unset IPA_PW
echo "  - stored FreeIPA join secret (root-only)"

# CIFS password (only if the share mount is enabled).
if [[ "${ENABLE_CIFS:-0}" == "1" ]]; then
  read -rs -p "Enter CIFS password for user '$CIFS_USER': " CIFS_PW; echo
  printf '%s' "$CIFS_PW" > "$ROOT/config/cifs.secret"
  chmod 600 "$ROOT/config/cifs.secret"
  unset CIFS_PW
  echo "  - stored CIFS secret (root-only)"
fi

echo "=============================================================="
echo " STEP 5/5 — Generate the ansible SSH keypair"
echo "=============================================================="
KEY="$ROOT/config/ansible_id_ed25519"
if [[ ! -f "$KEY" ]]; then
  ssh-keygen -t ed25519 -N "" -C "$ANSIBLE_USER@cobbler" -f "$KEY"
fi
echo "  - private key: $KEY   (keep this on your Ansible control node)"
echo "  - public key:  $KEY.pub (injected into deployed machines)"

cat <<EOF

============================================================
Cobbler installed. NEXT:
  sudo ./3-configure-cobbler.sh
This imports the ISOs, renders the autoinstall per release, publishes the local
package repos, and wires up the profiles.
============================================================
EOF
