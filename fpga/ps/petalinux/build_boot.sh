#!/bin/bash
# build_boot.sh - builds the Zybo SD-card boot files (BOOT.BIN, boot.scr, image.ub) for a given XSA.
#
#   source <petalinux 2025.2>/settings.sh
#   PETALINUX_PROJECT=<PetaLinux project> ./build_boot.sh <system_wrapper.xsa> <output dir>
#
# The PetaLinux project must contain this repo's project-spec (see fpga/ps/README.md, "Building the boot image").
set -e
[ $# -eq 2 ] || { echo "usage: PETALINUX_PROJECT=<dir> $0 <system_wrapper.xsa> <output dir>"; exit 1; }
[ -n "$PETALINUX" ] || { echo "PetaLinux environment not set: source <petalinux>/settings.sh first"; exit 1; }
P=${PETALINUX_PROJECT:?set PETALINUX_PROJECT to the PetaLinux project directory}
xsa=$(realpath "$1"); out=$(realpath -m "$2")
grep -q 'CHANGE_ME' "$P/project-spec/configs/rootfs_config" && {
    echo "rootfs_config still has the CHANGE_ME placeholder passwords: set CONFIG_ADD_EXTRA_USERS first"; exit 1; }

hw=$(mktemp -d); trap 'rm -rf "$hw"' EXIT
cp "$xsa" "$hw/system_wrapper.xsa"
cd "$P"
petalinux-config --get-hw-description "$hw" --silentconfig
petalinux-build
petalinux-package boot --fsbl images/linux/zynq_fsbl.elf --fpga images/linux/system.bit --u-boot --force
mkdir -p "$out"
cp images/linux/{BOOT.BIN,boot.scr,image.ub} "$out"/
ls -la "$out"
