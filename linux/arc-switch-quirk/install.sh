#!/usr/bin/env bash
# Install arc_switch_quirk with DKMS and make it load before xe/i915 at boot.
# usage: sudo linux/arc-switch-quirk/install.sh
# Safe to re-run: it replaces an existing install of the same version.
set -euo pipefail

NAME=arc-switch-quirk
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$(dirname "$0")/dkms.conf")
SRC=$(cd "$(dirname "$0")" && pwd)
KVER=$(uname -r)
MODPROBE_CONF=/etc/modprobe.d/$NAME.conf
INITRAMFS_MODULES=/etc/initramfs-tools/modules

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

echo "== Packages"
missing=()
command -v dkms >/dev/null || missing+=(dkms)
[[ -d /lib/modules/$KVER/build ]] || missing+=("linux-headers-$KVER")
if ((${#missing[@]})); then
  apt-get update -qq
  apt-get install -y "${missing[@]}"
else
  echo "  dkms and headers for $KVER already installed"
fi

echo "== Build and install module ($NAME $VER)"
if dkms status -m "$NAME" -v "$VER" | grep -q .; then
  dkms remove -m "$NAME" -v "$VER" --all >/dev/null
fi
rm -rf "/usr/src/$NAME-$VER"
mkdir -p "/usr/src/$NAME-$VER"
cp "$SRC"/arc_switch_quirk.c "$SRC"/Makefile "$SRC"/dkms.conf "/usr/src/$NAME-$VER/"
dkms add -m "$NAME" -v "$VER"
dkms build -m "$NAME" -v "$VER" -k "$KVER"
dkms install -m "$NAME" -v "$VER" -k "$KVER"

echo "== Load order"
mkdir -p "$(dirname "$MODPROBE_CONF")"
cat > "$MODPROBE_CONF" <<'EOF'
# Release the Arc on-board switch BAR0 before the GPU driver tries to resize BAR2.
softdep xe pre: arc_switch_quirk
softdep i915 pre: arc_switch_quirk
EOF
echo "  wrote $MODPROBE_CONF"

# If the GPU driver loads from the initramfs, the quirk has to be in there too.
if lsinitramfs "/boot/initrd.img-$KVER" 2>/dev/null | grep -qE '/(xe|i915)\.ko'; then
  grep -qx arc_switch_quirk "$INITRAMFS_MODULES" 2>/dev/null || echo arc_switch_quirk >> "$INITRAMFS_MODULES"
  echo "  GPU driver is in the initramfs; added arc_switch_quirk and rebuilding it"
  update-initramfs -u -k "$KVER"
else
  echo "  GPU driver loads after the initramfs; modprobe softdep is enough"
fi

echo
echo "Installed. Test without rebooting:"
echo "  sudo modprobe arc_switch_quirk dry_run=1 && sudo journalctl -k -b | grep arc_switch_quirk"
echo "Then reboot, and check with linux/check.sh"
