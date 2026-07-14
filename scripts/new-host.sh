#!/usr/bin/env bash
#
# new-host.sh — prepare ONE machine for deployment.
#   ./scripts/new-host.sh <fqdn> <release-label> [MAC]
#     <fqdn>          e.g. web01.example.com
#     <release-label> ubuntu2204 | ubuntu2404
#     [MAC]           optional; if given, a Cobbler system record is created so
#                     this exact machine auto-selects this release + autoinstall.
#
# It: (1) pre-creates the host in FreeIPA with a one-time password (OTP),
#     (2) stamps a per-host autoinstall (hostname + OTP) served over HTTP,
#     (3) optionally binds it to the machine's MAC in Cobbler.
#
# Run on the Cobbler server (needs the FreeIPA admin ticket: kinit admin).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config/cobbler.env"

FQDN="${1:-}"; LABEL="${2:-}"; MAC="${3:-}"
if [[ -z "$FQDN" || -z "$LABEL" ]]; then
  echo "Usage: $0 <fqdn> <${UBUNTU_2204_LABEL}|${UBUNTU_NOBLE_LABEL}> [MAC]" >&2
  exit 1
fi

WWW="/var/www/html"
BASE="$WWW/autoinstall/$LABEL/user-data"
[[ -f "$BASE" ]] || { echo "Base autoinstall not found: $BASE (run 3-configure-cobbler.sh)" >&2; exit 1; }

# 1) FreeIPA host + OTP (rotate if it already exists).
if ! klist -s 2>/dev/null; then echo "No Kerberos ticket. Run: kinit admin" >&2; exit 1; fi
OUT="$(ipa host-add "$FQDN" --random --force 2>&1)" || OUT="$(ipa host-mod "$FQDN" --random 2>&1)"
OTP="$(grep -i 'Random password:' <<<"$OUT" | sed 's/.*: *//')"
[[ -n "$OTP" ]] || { echo "Could not obtain OTP:" >&2; echo "$OUT" >&2; exit 1; }

# 2) Per-host autoinstall dir with hostname + OTP filled in.
HOSTDIR="$WWW/autoinstall/host/$FQDN"
mkdir -p "$HOSTDIR"
sed -e "s|hostname: ubuntu-host|hostname: ${FQDN%%.*}|" \
    -e "s|REPLACE_WITH_OTP|$OTP|" \
    "$BASE" > "$HOSTDIR/user-data"
printf 'instance-id: %s\n' "$FQDN" > "$HOSTDIR/meta-data"
echo "  - per-host autoinstall: $HOSTDIR/user-data"

# 3) Optional: bind to MAC via a Cobbler system record.
if [[ -n "$MAC" ]]; then
  KS="http://$COBBLER_SERVER_IP/autoinstall/host/$FQDN/"
  ISO="http://$COBBLER_SERVER_IP/isos/$LABEL.iso"
  cobbler system add --name="${FQDN%%.*}" --profile="${LABEL}-x86_64" \
    --mac="$MAC" --hostname="$FQDN" \
    --kernel-options="ip=dhcp url=$ISO autoinstall ds=nocloud-net;s=$KS" 2>/dev/null \
    || cobbler system edit --name="${FQDN%%.*}" --mac="$MAC" --hostname="$FQDN" \
       --kernel-options="ip=dhcp url=$ISO autoinstall ds=nocloud-net;s=$KS"
  cobbler sync 2>/dev/null || true
  echo "  - Cobbler system record bound to MAC $MAC"
fi

echo "READY: PXE-boot $FQDN — it will install $LABEL and enroll into FreeIPA."
