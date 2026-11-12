# Intel Arc Pro B60 on a Dell Precision 5820: fixing small BAR

On a Dell Precision 5820 Tower, an **Intel Arc Pro B60 24GB** gets full-size BAR (32GB) after one hidden BIOS value is changed: **MMIO High Granularity Size, 1G → 64G**. No BIOS flash, no ReBarUEFI, no kernel parameters.

Dell's default gives each PCIe root complex only 1GB of 64-bit MMIO space. A 24GB card needs a 32GB BAR, so the Linux `xe` driver can't resize it, and Intel's compute runtime (Level Zero) then hides the GPU from SYCL, oneAPI, llama.cpp, vLLM and OpenVINO. Raising the granularity to 64G lets `xe` resize the BAR itself at boot.

| | |
| --- | --- |
| Tested on | Precision 5820 Tower, BIOS **2.51.1**, Xeon W-2155, Ubuntu 26.04, kernel 7.0 |
| Card | Intel Arc Pro B60 24GB (Battlemage G21), slot 2 |
| Change | UEFI variable `SocketCommonRcConfig`, offset `0x4`, 2 bytes: `0x0000` → `0x0003` |
| Tool | [`setup_var.efi`](https://github.com/datasone/setup_var.efi) 0.3.1 from a UEFI shell |
| Result | `BAR2 resized to 32768MiB`; `sycl-ls` lists the B60 |

This is probably relevant to other Intel Purley / C422 / C621 workstations showing the same small-BAR symptom (Precision 7820/7920, HP Z4 G4, Lenovo P520), and to other large-VRAM cards (Arc B580/A770, 24–48GB GPUs). **Only the 5820 + B60 has been tested.** Offsets can change between BIOS versions, so confirm them yourself first ([appendix](#appendix-finding-the-setting-for-your-bios)).

> ⚠️ This writes a hidden firmware setting. A wrong offset in the wrong variable can stop a machine booting. Read before you write, and do this at your own risk.

## Symptoms

The card works for display, but nothing compute-related can see it. "Memory Map IO above 4GB" was already enabled in the BIOS, and turning Secure Boot on or off made no difference.

```
xe 0000:67:00.0: [drm] Attempting to resize bar from 256MiB -> 32768MiB
xe 0000:67:00.0: BAR 2 [mem size 0x800000000 64bit pref]: can't assign; no space
xe 0000:67:00.0: [drm] Failed to resize BAR2 to 32768MiB (-ENOSPC). Consider enabling 'Resizable BAR' support in your BIOS
xe 0000:67:00.0: [drm] Small BAR device
```

- `lspci -v` shows `Region 2: ... [size=256M]`.
- `sycl-ls` prints `WARNING: Resizable BAR not detected for device ...` and lists only the CPU. On the `xe` driver, Intel's compute runtime refuses small-BAR devices outright, so the GPU never appears to Level Zero or OpenCL ([intel/compute-runtime#997](https://github.com/intel/compute-runtime/issues/997)).
- Vulkan and display still work.

## Root cause

The BIOS gives each PCIe root complex (IIO stack) only **1GB** of 64-bit MMIO, which is too small for a 32GB BAR. The card and the driver are fine.

On Intel's Purley platform the BIOS splits the high MMIO region (MMIOH) between the CPU's IIO stacks in units of the *MMIO High Granularity Size*, one unit per stack by default. Dell ships 1G, which you can see in the root-bus windows:

```
pci_bus 0000:00: root bus resource [mem 0x380000000000-0x38003fffffff window]
pci_bus 0000:16: root bus resource [mem 0x380040000000-0x38007fffffff window]
pci_bus 0000:64: root bus resource [mem 0x380080000000-0x3800bfffffff window]   <- B60's stack: 1GB
pci_bus 0000:b2: root bus resource [mem 0x3800c0000000-0x3800ffffffff window]
```

Why the usual workarounds don't help:

- **`pci=realloc`** can rearrange bridge windows, but not grow a root window past what the firmware's ACPI `_CRS` reports.
- **[ReBarUEFI](https://github.com/xCuri0/ReBarUEFI)** resizes the BAR in firmware, but it would hit the same 1GB root window. The 5820 BIOS is also packaged with Intel BIOS Guard, so a modified image needs an external SPI programmer to flash.
- **Dell has no Resizable BAR option** for the 5820.

The Linux `xe` driver already tries to resize the BAR itself at probe. It only needs a large enough root window.

## The fix

Set **MMIO High Granularity Size** to **64G** (value `3`). It's an Intel reference-code option that Dell hides from the setup menu.

| Field | Value (BIOS 2.51.1) |
| --- | --- |
| UEFI variable | `SocketCommonRcConfig` |
| Variable GUID | `4402CA38-808F-4279-BCEC-5BAF8D59092F` |
| MMIO High Granularity Size | offset `0x4`, 2 bytes |
| MMIO High Base (leave alone) | offset `0x0`, 4 bytes, default `0` = 56T |

| Value | Granularity | Notes |
| --- | --- | --- |
| `0` | 1G | Dell default; too small |
| `1` | 4G | |
| `2` | 16G | still under a 32GB BAR |
| **`3`** | **64G** | **used here; fits a 32GB BAR** |
| `4` | 256G | |
| `5` | 1024G | |

Prerequisites:

- **Memory Map IO above 4GB** enabled in the normal BIOS setup (System Configuration). It was on in this setup; we didn't test with it off.
- **Secure Boot off** while you run the shell, because the UEFI shell and `setup_var.efi` are unsigned. You can turn it back on afterwards.
- A FAT32 USB stick.

## Step by step

This takes about 10 minutes at the machine.

1. **Build the USB stick.** On Linux, mount a FAT32 stick and run:

    ```bash
    git clone https://github.com/skipzx-lab/precision-5820-arc-b60-large-bar
    cd precision-5820-arc-b60-large-bar
    linux/make-usb.sh /media/$USER/<your-stick>
    ```

    This downloads a UEFI shell ([pbatard/UEFI-Shell](https://github.com/pbatard/UEFI-Shell) 26H1) and [`setup_var.efi`](https://github.com/datasone/setup_var.efi) 0.3.1, checks their SHA-256s, and copies them to the stick along with the scripts in [`usb/`](usb). Existing files on the stick are left alone. Manual setup: put `shellx64.efi` at `EFI/BOOT/BOOTX64.EFI`, and `setup_var.efi` plus `usb/*.nsh` in the root.
2. **Turn Secure Boot off.** Press F2 at the Dell logo, go to Secure Boot → Secure Boot Enable, untick it, then Apply → Exit.
3. **Boot the stick.** Press F12 and pick the USB under **UEFI Boot**. `startup.nsh` switches to the stick and prints a menu.
4. **Read first.** Run `mmioh-read.nsh`. Expect `0` for MMIO High Base and `0` for the granularity. **Stop if you see anything else, or if it asks for a variable ID.**
5. **Set 64G.** Run `mmioh-set.nsh`. The "after set" value should read `0x0003`.
6. **Reboot.** Type `reset`, and let the OS boot normally.

Each script appends its output to `mmioh.log` on the stick. The manual equivalent of steps 4–5:

```
fs0:
setup_var.efi SocketCommonRcConfig:0x0(4)
setup_var.efi SocketCommonRcConfig:0x4(2)
setup_var.efi SocketCommonRcConfig:0x4(2)=0x3
setup_var.efi SocketCommonRcConfig:0x4(2)
reset
```

## Verify

Run [`linux/check.sh`](linux/check.sh), or check by hand:

```
pci_bus 0000:64: root bus resource [mem 0x382000000000-0x382fffffffff window]
xe 0000:67:00.0: [drm] Attempting to resize bar from 256MiB -> 32768MiB
xe 0000:67:00.0: [drm] BAR2 resized to 32768MiB
xe 0000:67:00.0: [drm] VRAM[0]: ... CPU accessible size 0x00000005fa000000
```

| Check | Command | Before | After |
| --- | --- | --- | --- |
| Root window, GPU's stack | `sudo dmesg \| grep 'root bus resource'` | 1GB | 64GB |
| BAR2 | `sudo lspci -v -s <bdf>` | 256M | 32G |
| CPU-visible VRAM | `sudo dmesg \| grep 'CPU accessible'` | 256MiB | full 24GB |
| Level Zero | `sycl-ls` | CPU only | `[level_zero:gpu] Intel(R) Arc(TM) Pro B60 Graphics` |

### What it unlocks

With the card visible, llama.cpp's SYCL backend (`ghcr.io/ggml-org/llama.cpp:server-intel`, build b11277, `-fa on -ctk q8_0 -ctv q8_0 -b 4096 -ub 2048`) runs Qwen3.6-35B-A3B `UD-Q4_K_S` fully on the B60:

| Context already filled | Prompt processing (t/s) | Generation (t/s) |
| --- | --- | --- |
| 0 | 1,409 | 62.5 |
| 16k | 1,200 | 50.8 |
| 32k | 1,080 | 43.1 |

It loads at the model's full 262,144-token context (about 23.6 of 23.9GiB VRAM) and passed passphrase-retrieval tests at 8k, 32k, 47k, 123k and 239k tokens (a cold 239k-token prompt takes about 6 minutes to process). The card draws about 105–115W and stays near 60°C under load, on PCIe Gen3 x8.

## Arc A770 and other DG2 cards: the on-board switch

> ✅ Tested on an Arc A770 16GB in the same 5820, next to the B60 (kernel 7.0.0-43, `xe`). With the module below, the A770 boots with a 16GB BAR2 and the B60 keeps its 32GB:
>
> ```
> pcieport 0000:17:00.0: arc_switch_quirk: released BAR0 and parked it; 0000:19:00.0 can now resize BAR2
> pcieport 0000:16:00.0: bridge window [mem 0x381000000000-0x3813ffffffff 64bit pref]: assigned
> xe 0000:19:00.0: [drm] BAR2 resized to 16384MiB
> xe 0000:67:00.0: [drm] BAR2 resized to 32768MiB
> ```

With the BIOS fix in place, an A770 in a second slot still fails to resize, on both `i915` and `xe`:

```
xe 0000:19:00.0: [drm] Attempting to resize bar from 256MiB -> 16384MiB
xe 0000:19:00.0: [drm] Failed to resize BAR2 to 16384MiB (-ENOSPC). Consider enabling 'Resizable BAR' support in your BIOS
```

The root window isn't the problem this time. The A770's stack (bus `16`) gets its full 64GB:

```
pci_bus 0000:16: root bus resource [mem 0x381000000000-0x381fffffffff window]
```

The block is on the card. Every Arc card has a small PCIe switch in front of the GPU, and the switch's upstream port has its own 8MB BAR0. The firmware puts it in the same prefetchable window as the GPU's 256MB BAR2:

```
0000:17:00.0 PCI bridge [0604]: Intel Corporation Device [8086:4fa0] (rev 01)
        Region 0: Memory at 381ff0000000 (64-bit, prefetchable) [size=8M]
        Prefetchable memory behind bridge: 381fe0000000-381fefffffff [size=256M]
```

While that BAR0 is assigned, the PCI core can't release and grow the window above it, so the resize has nowhere to go. Intel posted a kernel quirk that releases this BAR0 on the Arc switch IDs `0x4fa0`, `0x4fa1` (DG2) and `0xe2ff` (Battlemage) ([patch](https://patchew.org/linux/20250918-xe-pci-rebar-2-v1-0-6c094702a074@intel.com/20250918-xe-pci-rebar-2-v1-1-6c094702a074@intel.com)), but it isn't in the kernel tested here.

### The workaround: `arc_switch_quirk`

[`linux/arc-switch-quirk`](linux/arc-switch-quirk) is a small out-of-tree module that does the same job without rebuilding the kernel. At load it finds DG2 switch upstream ports, and for each one whose GPU has a BAR2 smaller than its maximum, it:

1. releases the switch's BAR0, so the window can be resized,
2. moves the BAR0 register to an unreachable address (2^52), so the switch can't keep decoding its old range once the GPU's larger BAR2 is placed over it. This addresses the main review concern with the upstream patch,
3. saves the switch's config state, so a power-state restore doesn't put the old address back.

DKMS rebuilds it on kernel updates, and a `softdep` loads it before `xe` and `i915`. It leaves Battlemage switches alone by default, because `xe` already resizes the B60 on this machine. Add them with `ids=0x4fa0,0x4fa1,0xe2ff` if you need it.

```bash
sudo linux/arc-switch-quirk/install.sh
sudo modprobe arc_switch_quirk dry_run=1                        # report only, changes nothing
sudo journalctl -k -b | grep arc_switch_quirk
sudo reboot
linux/check.sh
```

To test without rebooting, `sudo rmmod arc_switch_quirk; sudo modprobe arc_switch_quirk reprobe=1` releases the BAR0 and rebinds the GPU driver so it retries the resize. If that GPU is driving the screen, the console blanks for a moment.

Undo: `sudo linux/arc-switch-quirk/uninstall.sh`, then reboot. The module changes nothing permanent; every reboot starts from the firmware's layout.

Here the A770 runs on `xe`, the same driver as the B60, via `i915.force_probe=!56a0 xe.force_probe=56a0` on the kernel command line. On `xe`, Level Zero hides small-BAR GPUs, so the A770 is missing from `sycl-ls` until the resize works. Removing those two parameters puts it back on `i915`, where a small BAR still works.

## Undo, risks and caveats

You're changing one stored settings value, not the firmware, so a BIOS reset undoes it.

- **Undo:** boot the stick and run `mmioh-undo.nsh` (writes `0x0`).
- **If it won't boot:** unplug the machine, remove the coin battery for about 60 seconds, and refit it. That restores Dell defaults (1G). Re-enable Memory Map IO above 4GB afterwards.
- **It reverts** whenever BIOS settings are reset to defaults, and possibly after a BIOS update. Keep the stick and re-apply the change.
- **Version-specific offsets.** Offset `0x4` is confirmed only for BIOS 2.51.1. On other versions or models, confirm the offset first (appendix).
- **Only tested on Linux.** The Linux `xe` driver does the resize itself. Windows wasn't tested.
- **Other OEM Purley boxes are untested.** The same Intel option probably exists, under a different variable layout.

## Appendix: finding the setting for your BIOS

All of this runs on Linux, offline, from Dell's update `.exe`. Nothing touches the machine's flash.

1. **Unpack the Dell update** with [platomav/BIOSUtilities](https://github.com/platomav/BIOSUtilities) (needs `7z`): `python main.py -e -o out Precision_5820_2.51.1.exe`. This extracts the AMI BIOS region as `System BIOS [V1 AMI] v2.51.1.bin`.
2. **Unpack the firmware volumes** with `UEFIExtract bios.bin all` ([LongSoft/UEFITool](https://github.com/LongSoft/UEFITool/releases), A75).
3. **Extract the setup forms** by running [IFRExtractor-RS](https://github.com/LongSoft/IFRExtractor-RS/releases) (1.6.1) on each `PE32 image section` body. The Intel reference-code options live in the `SocketSetup` module.
4. **Find the option:** search the `SocketSetup` IFR for `MMIO High Granularity Size`:

    ```
    VarStoreEfi Guid: 4402CA38-808F-4279-BCEC-5BAF8D59092F, VarStoreId: 0x2, Attributes: 0x7, Size: 0x73, Name: "SocketCommonRcConfig"
    OneOf Prompt: "MMIO High Granularity Size", ... VarStoreId: 0x2, VarOffset: 0x4, Flags: 0x11, Size: 16, Min: 0x0, Max: 0x5
        OneOfOption Option: "1G" Value: 0, Default, MfgDefault
        OneOfOption Option: "4G" Value: 1
        OneOfOption Option: "16G" Value: 2
        OneOfOption Option: "64G" Value: 3
        OneOfOption Option: "256G" Value: 4
        OneOfOption Option: "1024G" Value: 5
    ```

5. **Confirm the default** in the BIOS's `StdDefaults` NVRAM store, where `SocketCommonRcConfig` bytes 4–5 read `00 00` = 1G.

The variable isn't visible in Linux `efivarfs` on this machine, which is why the change goes through a UEFI shell.

## Credits

- [datasone/setup_var.efi](https://github.com/datasone/setup_var.efi): UEFI variable editor
- [pbatard/UEFI-Shell](https://github.com/pbatard/UEFI-Shell): UEFI shell builds
- [LongSoft/UEFITool](https://github.com/LongSoft/UEFITool) and [IFRExtractor-RS](https://github.com/LongSoft/IFRExtractor-RS)
- [platomav/BIOSUtilities](https://github.com/platomav/BIOSUtilities): Dell PFS extractor

## License

MIT for the scripts and docs in this repo. The downloaded tools keep their own licenses.
