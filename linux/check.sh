#!/usr/bin/env bash
# Check whether each Intel Arc dGPU has a full-size BAR and is visible to Level Zero.
# usage: linux/check.sh        (uses sudo for kernel log and lspci details)
set -uo pipefail

# Kernel log for this boot. dmesg's ring buffer can roll over on a long boot, so prefer the journal.
klog() { sudo journalctl -k -b --no-pager 2>/dev/null || sudo dmesg; }
LOG=$(klog)

mapfile -t GPUS < <(lspci -D -d 8086: -nn | grep -iE 'VGA|Display|3D' | grep -iE 'Battlemage|Arc|DG2' | cut -d' ' -f1)
if ((${#GPUS[@]} == 0)); then echo "No Intel Arc GPU found by lspci"; exit 1; fi

small=0
for BDF in "${GPUS[@]}"; do
  short=${BDF#0000:}
  echo "==================================================================="
  echo "GPU: $(lspci -s "$BDF" | cut -d' ' -f2-)  ($BDF)"
  echo "  driver: $(lspci -k -s "$BDF" | sed -n 's/.*Kernel driver in use: //p')"

  echo; echo "== BAR sizes"
  sudo lspci -v -s "$BDF" | grep -E 'Memory at' | sed 's/^\s*/  /'

  echo; echo "== Root bus window for this GPU's PCIe root complex"
  ROOT=$(readlink -f "/sys/bus/pci/devices/$BDF" | grep -oE 'pci0000:[0-9a-f]+' | head -1 | cut -d: -f2)
  grep -E "pci_bus 0000:${ROOT}: root bus resource \[mem 0x[0-9a-f]{9,}" <<<"$LOG" | sed 's/^.*pci_bus/  pci_bus/'

  echo; echo "== On-board switch (upstream port) BAR0"
  USP=$(readlink -f "/sys/bus/pci/devices/$BDF" | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' | tail -3 | head -1)
  if [[ -n $USP && $USP != "$BDF" ]]; then
    echo "  $USP $(lspci -nn -s "$USP" | grep -oE '\[8086:[0-9a-f]{4}\]')"
    r0=$(sudo lspci -v -s "$USP" | grep -E 'Region 0' | sed 's/^\s*//')
    echo "  ${r0:-no BAR0 assigned (released or absent)}"
  fi
  grep -E "arc_switch_quirk" <<<"$LOG" | grep -E "$USP|$short" | sed 's/^.*arc_switch_quirk/  arc_switch_quirk/'

  echo; echo "== GPU driver resize"
  grep -E "(xe|i915) ${BDF}.*(resize|Resize|Small BAR|CPU accessible)" <<<"$LOG" | sed 's/^.*\(xe\|i915\) /  \1 /'

  echo
  if grep -qE "${BDF}.*BAR2 resized" <<<"$LOG"; then
    echo "RESULT: BAR resized - large BAR is active."
  elif grep -qE "${BDF}.*(Small BAR|Failed to resize)" <<<"$LOG"; then
    echo "RESULT: small BAR. On xe, Level Zero / SYCL will not see this GPU. See README."
    small=1
  fi
done

if command -v docker >/dev/null; then
  echo "==================================================================="
  echo "== sycl-ls (llama.cpp full-intel image; first run pulls ~19GB)"
  docker run --rm --entrypoint sycl-ls --device /dev/dri \
    --group-add "$(getent group render | cut -d: -f3)" ghcr.io/ggml-org/llama.cpp:full-intel 2>&1 | sed 's/^/  /'
fi

exit $small
