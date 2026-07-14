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
# The compiled wheels (mod_wsgi, python-ldap, Cheetah3) are ABI-specific. If this
# server's Python differs from the build machine's, pip fails with a confusing
# "No matching distribution found for mod-wsgi". Check up front for a clear error.
BUILD_PY="$(cat "$ROOT/cobbler-server/wheelhouse/BUILD_PYTHON.txt" 2>/dev/null | grep -oE '3\.[0-9]+' | head -1)"
THIS_PY="$(python3 --version 2>&1 | grep -oE '3\.[0-9]+' | head -1)"
if [[ -n "$BUILD_PY" && "$BUILD_PY" != "$THIS_PY" ]]; then
  echo "ERROR: wheelhouse was built for Python $BUILD_PY but this server has $THIS_PY." >&2
  echo "       The compiled wheels (mod_wsgi/python-ldap/Cheetah3) won't match." >&2
  echo "       Rebuild the bundle on an Ubuntu release whose Python is $THIS_PY," >&2
  echo "       or install Cobbler on an Ubuntu release with Python $BUILD_PY." >&2
  exit 1
fi
# Ubuntu 24.04 marks system Python 'externally managed' (PEP 668), which blocks
# pip installs by default. --break-system-packages installs into the system
# environment anyway (Cobbler needs system-wide access like its distro packages).
pip3 install --no-index --find-links "$ROOT/cobbler-server/wheelhouse" \
  --break-system-packages cobbler

# pip installs Cobbler's config/data as "data files" UNDER the package prefix
# (e.g. /usr/local/lib/python3.12/dist-packages/etc/cobbler) instead of the real
# FHS paths. Relocate them so /etc/cobbler, /var/lib/cobbler, etc. exist.
echo "  - relocating Cobbler config/data from the pip prefix to / ..."
BASE="$(python3 -c 'import cobbler,os;print(os.path.dirname(os.path.dirname(cobbler.__file__)))')"
echo "    package prefix: $BASE"

# Copy the CONTENTS of a source dir into a dest dir (idempotent — safe to re-run,
# never nests like 'cp -a src dest/' does when dest already exists).
relocate() {  # $1 = source dir, $2 = destination dir
  [ -d "$1" ] || return 0
  mkdir -p "$2"
  cp -a "$1/." "$2/"
}
relocate "$BASE/etc/cobbler"     /etc/cobbler
relocate "$BASE/var/lib/cobbler" /var/lib/cobbler
relocate "$BASE/var/log/cobbler" /var/log/cobbler
relocate "$BASE/var/www/cobbler" /var/www/cobbler
relocate "$BASE/usr/share/cobbler" /usr/share/cobbler
relocate "$BASE/share/cobbler"   /usr/share/cobbler
find "$BASE" -name 'cobblerd*.service' -exec cp -f {} /etc/systemd/system/ \; 2>/dev/null || true
find "$BASE" -path '*apache2*' -name 'cobbler*.conf' -exec cp -f {} /etc/apache2/conf-available/ \; 2>/dev/null || true

if [[ ! -f /etc/cobbler/settings.yaml ]]; then
  echo "ERROR: /etc/cobbler/settings.yaml still missing after relocation." >&2
  echo "       Inspect: find $BASE -name settings.yaml" >&2
  exit 1
fi
echo "  - /etc/cobbler/settings.yaml is in place."

echo "=============================================================="
echo " STEP 3/5 — Wire up + start Cobbler services"
echo "=============================================================="

# The pip 'cobblerd' lands in /usr/local/bin, but the shipped systemd unit often
# points at /usr/bin/cobblerd. Write a unit that uses the ACTUAL binary path.
COBBLERD_BIN="$(command -v cobblerd || echo /usr/local/bin/cobblerd)"
echo "  - cobblerd binary: $COBBLERD_BIN"
cat > /etc/systemd/system/cobblerd.service <<UNIT
[Unit]
Description=Cobbler Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$COBBLERD_BIN -F
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

# Required runtime dirs.
mkdir -p /var/lib/tftpboot /var/log/cobbler/tasks /var/www/cobbler /var/lib/cobbler

# Apache: enable the modules Cobbler's WSGI/proxy config needs, plus its conf.
a2enmod proxy proxy_http rewrite wsgi 2>/dev/null || true
a2enconf cobbler 2>/dev/null || true

# External DHCP/DNS: Cobbler must NOT manage them; set server IPs.
# NOTE: these keys must be YAML booleans (true/false), NOT 0/1 — Cobbler's
# schema rejects integers ("0 should be instance of 'bool'").
SETTINGS="/etc/cobbler/settings.yaml"
sed -i \
  -e "s/^manage_dhcp:.*/manage_dhcp: false/" \
  -e "s/^manage_dhcp_v4:.*/manage_dhcp_v4: false/" \
  -e "s/^manage_dhcp_v6:.*/manage_dhcp_v6: false/" \
  -e "s/^manage_dns:.*/manage_dns: false/" \
  -e "s/^manage_tftpd:.*/manage_tftpd: true/" \
  -e "s#^server:.*#server: $COBBLER_SERVER_IP#" \
  -e "s#^next_server_v4:.*#next_server_v4: $COBBLER_SERVER_IP#" \
  "$SETTINGS"

# The 'cobbler' CLI connects to the API at the 'server' IP by default. If that IP
# isn't locally reachable (e.g. placeholder, or before Apache proxy is wired) you
# get 'No route to host'. Force the CLI to use 127.0.0.1 instead.
if grep -q '^client_use_localhost:' "$SETTINGS"; then
  sed -i 's/^client_use_localhost:.*/client_use_localhost: true/' "$SETTINGS"
else
  echo 'client_use_localhost: true' >> "$SETTINGS"
fi

systemctl daemon-reload
systemctl enable --now apache2 tftpd-hpa 2>/dev/null || true
systemctl restart apache2 2>/dev/null || true
systemctl enable cobblerd 2>/dev/null || true
systemctl restart cobblerd

# Verify cobblerd actually came up — retry, then fail loudly with diagnostics.
echo "  - waiting for cobblerd to respond..."
ok=0
for i in $(seq 1 15); do
  if cobbler version >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
if [[ "$ok" != "1" ]]; then
  echo "ERROR: cobblerd did not come up. Diagnostics:" >&2
  systemctl --no-pager -l status cobblerd 2>&1 | tail -20 >&2
  echo "--- last cobbler log ---" >&2
  journalctl -u cobblerd --no-pager -n 30 2>/dev/null >&2 || true
  exit 1
fi
echo "  - cobblerd is up: $(cobbler version 2>/dev/null)"

# Stage PXE boot loaders + initial sync (now that the daemon is confirmed up).
# Cobbler 3.3.x uses 'mkloaders' (the old 'get-loaders' was removed).
cobbler mkloaders || echo "  (warn) cobbler mkloaders had issues"
cobbler sync || echo "  (warn) cobbler sync had issues"

echo "=============================================================="
echo " STEP 4/5 — Set the LOCAL ADMIN password (prompted, hashed)"
echo "=============================================================="
HASH_FILE="$ROOT/config/localadmin.hash"
if [[ -s "$HASH_FILE" ]]; then
  echo "  - local admin hash already set (delete $HASH_FILE to re-prompt) — skipping"
elif command -v mkpasswd >/dev/null 2>&1; then
  echo "Enter the password for local admin user '$LOCALADMIN_USER' (break-glass, root/sudo):"
  HASH="$(mkpasswd -m sha-512)"          # prompts securely, no echo
  umask 077; printf '%s\n' "$HASH" > "$HASH_FILE"
  echo "  - stored SHA-512 hash in $HASH_FILE (no plaintext kept)"
else
  # Fallback: prompt, then hash with Python's crypt (SHA-512).
  read -rs -p "Enter password for local admin '$LOCALADMIN_USER': " PW; echo
  HASH="$(python3 -c 'import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))' "$PW")"
  unset PW
  umask 077; printf '%s\n' "$HASH" > "$HASH_FILE"
  echo "  - stored SHA-512 hash in $HASH_FILE (no plaintext kept)"
fi

# FreeIPA enrollment password (used by the pituah first-boot join). Stored
# root-only; it is injected into the published post-install script by step 3.
if [[ -s "$ROOT/config/ipa_join.secret" ]]; then
  echo "  - FreeIPA join secret already set — skipping"
else
  echo
  read -rs -p "Enter FreeIPA enrollment password for principal '$IPA_PRINCIPAL': " IPA_PW; echo
  printf '%s' "$IPA_PW" > "$ROOT/config/ipa_join.secret"
  chmod 600 "$ROOT/config/ipa_join.secret"
  unset IPA_PW
  echo "  - stored FreeIPA join secret (root-only)"
fi

# CIFS password (only if the share mount is enabled).
if [[ "${ENABLE_CIFS:-0}" == "1" ]]; then
  if [[ -s "$ROOT/config/cifs.secret" ]]; then
    echo "  - CIFS secret already set — skipping"
  else
    read -rs -p "Enter CIFS password for user '$CIFS_USER': " CIFS_PW; echo
    printf '%s' "$CIFS_PW" > "$ROOT/config/cifs.secret"
    chmod 600 "$ROOT/config/cifs.secret"
    unset CIFS_PW
    echo "  - stored CIFS secret (root-only)"
  fi
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
