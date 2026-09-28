### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
##
## Droidspaces Kernel — OnePlus SM8750 ("sun") / LineageOS 23.x
## Generated for GitHub Actions builds of droidspaces-oneplus-sm8750.

### AnyKernel setup
properties() { '
kernel.string=Droidspaces Kernel (SM8750 / sun)
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
# LineageOS codenames for the SM8750 (sun) family
device.name1=dodge
device.name2=erhai
device.name3=hummer
device.name4=ktm
# ...plus the OPPO/OnePlus OTA product names, because several ROMs report
# ro.product.device as one of these instead of the LineageOS codename
# (an OnePlus Pad 2 Pro reports OP615EL1 / OP6190L1).
device.name5=OP5D0DL1
device.name6=OP5D55L1
device.name7=OP615EL1
device.name8=OP6190L1
device.name9=OP60EBL1
device.name10=OP6113L1
device.name11=PLQ110
device.name12=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
## boot shell variables
BLOCK=boot
IS_SLOT_DEVICE=auto
RAMDISK_COMPRESSION=auto
PATCH_VBMETA_FLAG=auto
NO_MAGISK_CHECK=1

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

ui_print " "
ui_print "  Droidspaces Kernel for OnePlus SM8750"
ui_print "  kernel : $(uname -r)"
ui_print " "

# Resolve occasional file-system I/O latency issues that can make the
# bundled binaries fail to execute right after unzip.
sync
sleep 0.5
chmod -R 755 $AKHOME/tools;

## boot install
# GKI boot images on this platform are header v4 and normally have no ramdisk
# in /boot (the generic ramdisk lives in init_boot), so split_boot + flash_boot
# is the correct path.  If a ramdisk *is* present we repack it properly instead.
split_boot;
if [ -f "split_img/ramdisk.cpio" ]; then
  unpack_ramdisk;
  write_boot;
else
  flash_boot;
fi;
## end boot install
