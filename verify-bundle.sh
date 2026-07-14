#!/usr/bin/env bash
#
# verify-bundle.sh — sanity-check the offline bundle before transferring it.
#   ./verify-bundle.sh [path-to-bundle]

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="${1:-$ROOT/cobbler-offline-bundle.tar.gz}"

echo "=============================================================="
echo " Cobbler offline bundle readiness check"
echo "=============================================================="
[[ -f "$BUNDLE" ]] || { echo "MISSING bundle: $BUNDLE"; exit 1; }
echo "Bundle: $BUNDLE"
echo "Size:   $(du -h "$BUNDLE" | cut -f1)"

LIST="$(mktemp)"; tar -tzf "$BUNDLE" > "$LIST"

count() { grep -cE "$1" "$LIST" || true; }
have()  { grep -qE "$1" "$LIST" && echo "  OK   $2" || echo "  MISS $2"; }

echo; echo "--- Cobbler server ---"
echo "  server .debs:      $(count '^cobbler-server/apt-debs/.*\.deb$')"
echo "  pip wheels:        $(count '^cobbler-server/wheelhouse/.*\.(whl|tar\.gz)$')"

echo; echo "--- per-release post-install repos ---"
for c in jammy noble; do
  echo "  $c debs:          $(count "^localdebs/$c/.*\\.deb$")   tarball: $(count "^localdebs/$c/localdebs.tar.gz$")"
done

echo; echo "--- ISOs ---"
grep -E '^isos/.*\.iso$' "$LIST" | sed 's/^/  /' || echo "  (none)"

echo; echo "--- scripts + templates ---"
have '^config/cobbler.env$'                 'config/cobbler.env'
have '^autoinstall/ubuntu.user-data.tmpl$'  'autoinstall/ubuntu.user-data.tmpl'
have '^2-install-offline.sh$'               '2-install-offline.sh'
have '^3-configure-cobbler.sh$'             '3-configure-cobbler.sh'
have '^scripts/new-host.sh$'                'scripts/new-host.sh'

rm -f "$LIST"
echo; echo "=============================================================="
echo " Review counts above: server debs > 0, wheels > 0, each release has debs+tarball, 2 ISOs."
echo "=============================================================="
