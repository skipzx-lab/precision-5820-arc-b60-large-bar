// SPDX-License-Identifier: GPL-2.0
/*
 * arc_switch_quirk - let the xe driver resize an Intel Arc GPU's BAR2 when
 * the PCIe switch built into the card pins the upstream bridge window.
 *
 * Intel Arc cards carry a small PCIe switch. Its upstream port has an 8MB
 * BAR0 that the firmware places in the same prefetchable window as the GPU's
 * 256MB BAR2. While that BAR0 is assigned, the PCI core can't grow or move
 * the window, so xe's resize at probe fails with -ENOSPC even when the root
 * complex has plenty of free address space.
 *
 * This does at runtime what Intel's proposed kernel quirk does at boot
 * ("PCI: Release BAR0 of an integrated bridge to allow GPU BAR resize"):
 * release the switch's BAR0 so the window can be resized. Unlike that quirk,
 * it also moves the BAR0 hardware register to an address nothing can reach
 * (above any CPU physical address and DMA mask), so the switch can't keep
 * decoding the old range once the GPU's enlarged BAR2 is placed over it.
 *
 * It only touches a switch when the GPU below it has a BAR2 smaller than the
 * largest size the GPU supports. Load it before xe (see softdep in the
 * install script), or load it later with reprobe=1 to rebind the driver.
 */
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/module.h>
#include <linux/pci.h>

/* dev_*() messages carry the device's driver name, so tag ours for grep. */
#define QPFX KBUILD_MODNAME ": "

/*
 * Default: the DG2 (Arc A-series) switch upstream ports from Intel's quirk.
 * 0xe2ff (Battlemage) is left out by default because xe already resizes the
 * B60 on the tested machine; add it with ids=0x4fa0,0x4fa1,0xe2ff if needed.
 */
static ushort ids[8] = { 0x4fa0, 0x4fa1 };
static int nr_ids = 2;
module_param_array(ids, ushort, &nr_ids, 0444);
MODULE_PARM_DESC(ids, "Intel switch upstream port device IDs to act on (default 0x4fa0,0x4fa1)");

static bool dry_run;
module_param(dry_run, bool, 0444);
MODULE_PARM_DESC(dry_run, "Only report what would be done (default 0)");

static bool reprobe;
module_param(reprobe, bool, 0444);
MODULE_PARM_DESC(reprobe, "Rebind the GPU's driver after releasing, so it retries the resize (default 0)");

/*
 * Where the released BAR0 is parked. 2^52 is above the 46-bit physical
 * address space of Skylake-SP / Cascade Lake Xeons and above any DMA mask a
 * GPU on this platform uses, so no CPU access or DMA can land in it. The
 * root port never forwards it either, as it's outside every bridge window.
 */
#define PARK_ADDR	(1ULL << 52)

/* Find the display-class function behind a switch upstream port. */
static struct pci_dev *find_gpu(struct pci_dev *usp)
{
	struct pci_dev *dsp, *dev;

	if (!usp->subordinate)
		return NULL;

	list_for_each_entry(dsp, &usp->subordinate->devices, bus_list) {
		if (!dsp->subordinate)
			continue;
		list_for_each_entry(dev, &dsp->subordinate->devices, bus_list) {
			if (dev->vendor == PCI_VENDOR_ID_INTEL &&
			    (dev->class >> 16) == PCI_BASE_CLASS_DISPLAY)
				return pci_dev_get(dev);
		}
	}
	return NULL;
}

/* True if the GPU's BAR2 is smaller than the largest size it supports. */
static bool gpu_has_small_bar(struct pci_dev *gpu, u64 *cur, u64 *max)
{
	int max_size = pci_rebar_get_max_size(gpu, 2);

	if (max_size < 0)
		return false;

	*cur = pci_resource_len(gpu, 2);
	*max = pci_rebar_size_to_bytes(max_size);
	return *cur < *max;
}

/* Point the switch's 64-bit BAR0 at PARK_ADDR and confirm it took. */
static int park_bar0(struct pci_dev *usp)
{
	u32 lo, hi;

	/*
	 * High dword first: the BAR then jumps straight from its old address
	 * into unreachable space, instead of passing through a low address
	 * inside the root window between the two writes.
	 */
	pci_write_config_dword(usp, PCI_BASE_ADDRESS_1,
			       upper_32_bits(PARK_ADDR));
	pci_write_config_dword(usp, PCI_BASE_ADDRESS_0,
			       lower_32_bits(PARK_ADDR));

	pci_read_config_dword(usp, PCI_BASE_ADDRESS_0, &lo);
	pci_read_config_dword(usp, PCI_BASE_ADDRESS_1, &hi);

	if ((((u64)hi << 32) | (lo & PCI_BASE_ADDRESS_MEM_MASK)) != PARK_ADDR)
		return -EIO;

	/*
	 * Refresh the saved config space, or a later pci_restore_state() (power
	 * state changes, resets) would write the old BAR0 address back.
	 */
	pci_save_state(usp);
	return 0;
}

/* Returns 1 if the switch was handled, 0 if skipped, <0 on error. */
static int handle_switch(struct pci_dev *usp, struct pci_dev **gpu_out)
{
	struct resource *res = pci_resource_n(usp, 0);
	struct pci_dev *gpu;
	u64 cur, max;
	int ret;

	if (pci_pcie_type(usp) != PCI_EXP_TYPE_UPSTREAM) {
		pci_info(usp, QPFX "not a switch upstream port, skipping\n");
		return 0;
	}

	if (!res->parent || !(res->flags & IORESOURCE_MEM_64)) {
		pci_info(usp, QPFX "BAR0 not assigned, nothing to release\n");
		return 0;
	}

	gpu = find_gpu(usp);
	if (!gpu) {
		pci_info(usp, QPFX "no Intel GPU found behind this switch, skipping\n");
		return 0;
	}

	if (!gpu_has_small_bar(gpu, &cur, &max)) {
		pci_info(usp, QPFX "GPU %s already has a full-size BAR2, skipping\n",
			 pci_name(gpu));
		pci_dev_put(gpu);
		return 0;
	}

	pci_info(usp, QPFX "BAR0 %pR pins the window of GPU %s (BAR2 %lluMiB of %lluMiB)\n",
		 res, pci_name(gpu), cur >> 20, max >> 20);

	if (dry_run) {
		pci_info(usp, QPFX "dry_run: would release BAR0 and park it at %#llx\n",
			 PARK_ADDR);
		pci_dev_put(gpu);
		return 1;
	}

	ret = pci_release_resource(usp, 0);
	if (ret) {
		pci_err(usp, QPFX "releasing BAR0 failed (%d), leaving it alone\n", ret);
		pci_dev_put(gpu);
		return ret;
	}

	ret = park_bar0(usp);
	if (ret)
		pci_warn(usp, QPFX "BAR0 didn't accept the parking address; it may still decode its old range\n");

	/* Stop the PCI core from ever assigning it again. */
	res->flags = 0;

	pci_info(usp, QPFX "released BAR0%s; %s can now resize BAR2\n",
		 ret ? "" : " and parked it", pci_name(gpu));

	*gpu_out = gpu;
	return 1;
}

static int __init arc_switch_quirk_init(void)
{
	struct pci_dev *gpus[16];
	int nr_gpus = 0, handled = 0, i;

	pci_lock_rescan_remove();

	for (i = 0; i < nr_ids; i++) {
		struct pci_dev *usp = NULL;

		while ((usp = pci_get_device(PCI_VENDOR_ID_INTEL, ids[i], usp))) {
			struct pci_dev *gpu = NULL;
			int ret = handle_switch(usp, &gpu);

			if (ret > 0)
				handled++;
			if (gpu) {
				if (nr_gpus < ARRAY_SIZE(gpus))
					gpus[nr_gpus++] = gpu;
				else
					pci_dev_put(gpu);
			}
		}
	}

	pci_unlock_rescan_remove();

	for (i = 0; i < nr_gpus; i++) {
		struct pci_dev *gpu = gpus[i];

		if (gpu->dev.driver) {
			if (reprobe) {
				pci_info(gpu, QPFX "rebinding %s so it retries the resize\n",
					 gpu->dev.driver->name);
				if (device_reprobe(&gpu->dev))
					pci_warn(gpu, QPFX "rebind failed\n");
			} else {
				pci_info(gpu, QPFX "driver %s already bound; reload it or reboot to resize\n",
					 gpu->dev.driver->name);
			}
		}
		pci_dev_put(gpu);
	}

	if (!handled)
		pr_info("no matching switch needed changes\n");

	return 0;
}

static void __exit arc_switch_quirk_exit(void)
{
	/* Nothing to undo: the released BAR0 is unused, and a reboot restores it. */
}

module_init(arc_switch_quirk_init);
module_exit(arc_switch_quirk_exit);

MODULE_DESCRIPTION("Release the BAR0 of Intel Arc on-board PCIe switches so the GPU BAR can be resized");
MODULE_AUTHOR("S.J. Murdoch");
MODULE_LICENSE("GPL");
