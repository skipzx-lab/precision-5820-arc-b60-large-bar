#!/usr/bin/env bash
# Remove arc_switch_quirk and its boot configuration. Takes effect at the next reboot.
# usage: sudo linux/arc-switch-quirk/uninstall.sh
set -euo pipefail

NAME=arc-switch-quirk
KVER=$(uname -r)

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

rm -f "/etc/modprobe.d/$NAME.conf"
if [[ -f /etc/initramfs-tools/modules ]] && grep -qx arc_switch_quirk /etc/initramfs-tools/modules; then
  sed -i '/^arc_switch_quirk$/d' /etc/initramfs-tools/modules
fi

for v in $(dkms status -m "$NAME" 2>/dev/null | sed -n "s|^$NAME/\([^,:]*\).*|\1|p" | sort -u); do
  dkms remove -m "$NAME" -v "$v" --all
  rm -rf "/usr/src/$NAME-$v"
done

update-initramfs -u -k "$KVER"
echo "Removed. Reboot to return the switch BAR0 to its firmware default."
