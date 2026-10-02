@echo -off
echo "=== before set ===" >a mmioh.log
setup_var.efi SocketCommonRcConfig:0x4(2) >a mmioh.log
echo "=== write 0x3 (64G) ===" >a mmioh.log
setup_var.efi SocketCommonRcConfig:0x4(2)=0x3 >a mmioh.log
echo "=== after set ===" >a mmioh.log
setup_var.efi SocketCommonRcConfig:0x4(2) >a mmioh.log
type mmioh.log
echo "If the after-set value is 0x0003, type: reset"
