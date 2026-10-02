@echo -off
echo "MMIO High Base (expect 0 = 56T):"
setup_var.efi SocketCommonRcConfig:0x0(4)
echo "MMIO High Granularity Size (expect 0 = 1G before the fix, 3 = 64G after):"
setup_var.efi SocketCommonRcConfig:0x4(2)
echo "=== read ===" >a mmioh.log
setup_var.efi SocketCommonRcConfig:0x0(4) SocketCommonRcConfig:0x4(2) >a mmioh.log
