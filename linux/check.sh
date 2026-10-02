#!/usr/bin/env bash
# Check whether an Intel Arc dGPU has a full-size BAR and is visible to Level Zero.
# usage: linux/check.sh        (uses sudo for dmesg/lspci details)
set -uo pipefail

BDF=$(lspci -D -d 8086: -nn | grep -iE 'VGA|Display|3D' | grep -iE 'Battlemage|Arc' | head -1 | cut -d' ' -f1)
if [[ -z $BDF ]]; then echo "No Intel Arc/Battlemage GPU found by lspci"; exit 1; fi
echo "GPU: $(lspci -s "$BDF" | cut -d' ' -f2-)  ($BDF)"

echo; echo "== BAR sizes"
sudo lspci -v -s "$BDF" | grep -E 'Memory at' | sed 's/^\s*/  /'

echo; echo "== Root bus window for the GPU's PCIe root complex"
ROOT=$(readlink -f "/sys/bus/pci/devices/$BDF" | grep -oE 'pci0000:[0-9a-f]+' | head -1 | cut -d: -f2)
sudo dmesg | grep -E "pci_bus 0000:${ROOT}: root bus resource \[mem 0x[0-9a-f]{9,}" | sed 's/^/  /'

echo; echo "== xe driver"
sudo dmesg | grep -E 'xe .*(resize|Resize|Small BAR|CPU accessible)' | sed 's/^/  /'

echo
if sudo dmesg | grep -q 'BAR2 resized'; then
  echo "RESULT: BAR resized - large BAR is active."
elif sudo dmesg | grep -q 'Small BAR device'; then
  echo "RESULT: small BAR - Level Zero / SYCL will not see this GPU. See README."
fi

if command -v docker >/dev/null; then
  echo; echo "== sycl-ls (llama.cpp full-intel image; first run pulls ~19GB)"
  docker run --rm --entrypoint sycl-ls --device /dev/dri \
    --group-add "$(getent group render | cut -d: -f3)" ghcr.io/ggml-org/llama.cpp:full-intel 2>&1 | sed 's/^/  /'
fi
