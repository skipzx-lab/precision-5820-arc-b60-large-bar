@echo -off
echo "=== undo: write 0x0 (1G, Dell default) ===" >a mmioh.log
setup_var.efi SocketCommonRcConfig:0x4(2)=0x0 >a mmioh.log
setup_var.efi SocketCommonRcConfig:0x4(2) >a mmioh.log
type mmioh.log
