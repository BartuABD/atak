#!/bin/bash
# build_gui.sh - cross-compiles atak_gui for the Zybo (Cortex-A9, hard float) with the toolchain of a built
# PetaLinux project. Output: atak_gui next to this script.
#
#   PETALINUX_PROJECT=<built PetaLinux project> ./build_gui.sh
set -e
P=${PETALINUX_PROJECT:?set PETALINUX_PROJECT to the built PetaLinux project directory}
D=$(cd "$(dirname "$0")" && pwd)
T=$P/build/tmp
CC=$T/sysroots-components/x86_64/gcc-cross-arm/usr/bin/arm-amd-linux-gnueabi/arm-amd-linux-gnueabi-gcc
BU=$T/sysroots-components/x86_64/binutils-cross-arm/usr/bin/arm-amd-linux-gnueabi
SR=$(ls -d $T/work/zynq_generic_7z020-amd-linux-gnueabi/linux-xlnx/*/recipe-sysroot | head -1)
[ -x "$CC" ] && [ -d "$SR" ] || { echo "toolchain / sysroot not found under $T (run petalinux-build first)"; exit 1; }

# gcc looks for as / ld under their plain names (-B): link the prefixed binutils there
X=$(mktemp -d); trap 'rm -rf "$X"' EXIT
for t in as ld ld.bfd ar nm objcopy strip; do ln -s "$BU/arm-amd-linux-gnueabi-$t" "$X/$t"; done

rm -f "$D/atak_gui"
"$CC" --sysroot="$SR" -B"$X/" -march=armv7-a -mthumb -mfpu=neon -mfloat-abi=hard -O2 -Wall \
    -o "$D/atak_gui" "$D/atak_gui.c" -lm
file "$D/atak_gui"
