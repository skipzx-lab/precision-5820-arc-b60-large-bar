@echo -off
# Switch to whichever filesystem holds setup_var.efi, then show the menu.
if exist fs0:\setup_var.efi then
  fs0:
endif
if exist fs1:\setup_var.efi then
  fs1:
endif
if exist fs2:\setup_var.efi then
  fs2:
endif
if exist fs3:\setup_var.efi then
  fs3:
endif
if exist fs4:\setup_var.efi then
  fs4:
endif
if exist fs5:\setup_var.efi then
  fs5:
endif
echo " "
echo "=== Precision 5820 MMIO High Granularity fix ==="
echo "1. mmioh-read.nsh   read only, changes nothing (expect 0 and 0)"
echo "2. mmioh-set.nsh    set MMIO High Granularity Size to 64G"
echo "   mmioh-undo.nsh   back to the Dell default (1G)"
echo "3. reset            reboot"
