#!/usr/bin/env bash
# Builds the Windows setup seed ISO and uploads it to Proxmox ISO storage.
# The seed ISO carries autounattend.xml, firstlogon.ps1, and the VirtIO SCSI
# driver under $WinPEDriver$ (auto-loaded by WinPE from any removable media).
#
# Usage:
#   ADMIN_PASSWORD='...' ./make-seed.sh [/path/to/virtio-win.iso] root@pve1 [/var/lib/vz/template/iso]
#
# If the virtio ISO argument is omitted, ./virtio-win.iso next to this script is used,
# and downloaded from the Fedora project if it is not there yet.
set -euo pipefail

USAGE="usage: $0 [virtio-win.iso] root@pve-host [iso-dir]"
VIRTIO_URL="${VIRTIO_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso}"
HERE_DIR="$(cd "$(dirname "$0")" && pwd)"

# First argument is the virtio ISO only if it looks like one; otherwise use the default path
if [[ "${1:-}" == *.iso ]]; then
    VIRTIO_ISO="$1"; shift
else
    VIRTIO_ISO="$HERE_DIR/virtio-win.iso"
fi
PVE_HOST="${1:?$USAGE}"
PVE_ISO_DIR="${2:-/var/lib/vz/template/iso}"
: "${ADMIN_PASSWORD:?set ADMIN_PASSWORD (must match admin_password in the pkrvars file)}"

if [ ! -s "$VIRTIO_ISO" ]; then
    echo "$VIRTIO_ISO not found, downloading from $VIRTIO_URL"
    PART="$VIRTIO_ISO.part"
    curl -fL --retry 3 --connect-timeout 20 -o "$PART" "$VIRTIO_URL" \
        || { rm -f "$PART"; echo "download failed" >&2; exit 1; }
    # Reject truncated or non-ISO downloads (e.g. an HTML error page)
    bsdtar -tf "$PART" >/dev/null 2>&1 \
        || { rm -f "$PART"; echo "downloaded file is not a readable ISO" >&2; exit 1; }
    mv "$PART" "$VIRTIO_ISO"
    echo "saved $VIRTIO_ISO"
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/win2022-seed.XXXXXX")"
trap 'chmod -R u+w "$STAGE" 2>/dev/null; rm -rf "$STAGE"' EXIT

cp -r "$HERE/seed/." "$STAGE/"
DRV="$STAGE/\$WinPEDriver\$"
mkdir -p "$DRV"

# Server 2022 VirtIO SCSI driver (flattened into $WinPEDriver$)
# The virtio-win ISO stores the 2k22 files as hard links into the amd64/ tree, so
# extract both trees; `--strip-components` with specific member paths extracts nothing.
VIRTIO_TMP="$STAGE/virtio"
mkdir -p "$VIRTIO_TMP"
bsdtar -xf "$VIRTIO_ISO" -C "$VIRTIO_TMP" 'vioscsi/*' 'amd64/*' 2>/dev/null || true
for f in vioscsi.inf vioscsi.sys vioscsi.cat; do
    src="$VIRTIO_TMP/vioscsi/2k22/amd64/$f"
    [ -s "$src" ] || { echo "missing $src in $VIRTIO_ISO" >&2; exit 1; }
    cp "$src" "$DRV/$f"
done
chmod -R u+w "$VIRTIO_TMP"
rm -rf "$VIRTIO_TMP"

# Render the password, XML-escaped
ADMIN_PASSWORD="$ADMIN_PASSWORD" python3 - "$STAGE/autounattend.xml" <<'PY'
import os, sys
from xml.sax.saxutils import escape
path = sys.argv[1]
pw = escape(os.environ["ADMIN_PASSWORD"], {'"': "&quot;"})
data = open(path, encoding="utf-8").read().replace("__ADMIN_PASSWORD__", pw)
open(path, "w", encoding="utf-8").write(data)
PY

ISO="$HERE/win2022-seed.iso"
xorriso -as mkisofs -r -J -V WIN2022SEED -o "$ISO" "$STAGE" >/dev/null 2>&1
echo "built $ISO"

scp "$ISO" "$PVE_HOST:$PVE_ISO_DIR/win2022-seed.iso"
echo "uploaded to $PVE_HOST:$PVE_ISO_DIR/win2022-seed.iso"
echo "Delete the local and Proxmox copies after the build: they contain the admin password."
