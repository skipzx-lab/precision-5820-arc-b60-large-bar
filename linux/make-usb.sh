#!/usr/bin/env bash
# Populate a mounted FAT32 USB stick with a UEFI shell, setup_var.efi and the scripts in ../usb.
# usage: linux/make-usb.sh /media/$USER/MYSTICK
# Existing files on the stick are left alone; only EFI/BOOT/BOOTX64.EFI, setup_var.efi and *.nsh are written.
set -euo pipefail

DEST=${1:?usage: make-usb.sh <mounted FAT32 path>}
HERE=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Pinned versions used on the tested machine. Bump deliberately, and update the hashes with them.
SHELL_URL=https://github.com/pbatard/UEFI-Shell/releases/download/26H1/shellx64.efi
SHELL_SHA=4ea080ddd576117cd04f5c02d16712ea5d9249c0752214d8e4055e460d7b11e0
SETUPVAR_URL=https://github.com/datasone/setup_var.efi/releases/download/0.3.1/setup_var.efi
SETUPVAR_SHA=cbe5777b61276d3f3506a28b34845326e92f6c171bff59177e3912fe20f49840

fetch() {  # url sha256 out
  curl -fsSL -o "$3" "$1"
  echo "$2  $3" | sha256sum -c --quiet - || { echo "checksum mismatch for $1" >&2; exit 1; }
}

fetch "$SHELL_URL" "$SHELL_SHA" "$TMP/shellx64.efi"
fetch "$SETUPVAR_URL" "$SETUPVAR_SHA" "$TMP/setup_var.efi"

mkdir -p "$DEST/EFI/BOOT"
cp "$TMP/shellx64.efi" "$DEST/EFI/BOOT/BOOTX64.EFI"
cp "$TMP/setup_var.efi" "$DEST/setup_var.efi"
cp "$HERE"/usb/*.nsh "$DEST/"
sync

echo "USB ready at $DEST:"
( cd "$DEST" && ls EFI/BOOT/BOOTX64.EFI setup_var.efi ./*.nsh )
echo "Next: Secure Boot off (F2), boot the stick from F12 > UEFI Boot, run mmioh-read.nsh first."
