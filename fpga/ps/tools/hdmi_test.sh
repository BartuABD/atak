#!/bin/sh
# hdmi_test.sh - first HDMI test without any driver: copies a raw 1280x720 picture into the reserved screen memory
# and starts the AXI VDMA read channel (MM2S) with busybox devmem. Run as root:  sudo sh hdmi_test.sh [picture.raw]
# Picture format: 1280 x 720 pixels, 4 bytes per pixel in memory order Blue, Green, Red, unused (3,686,400 bytes).
# Addresses: VDMA registers 0x4300_0000 (block design), screen memory 0x3F00_0000 (reserved in system-user.dtsi).
VDMA=0x43000000
FB=0x3F000000
W=1280; H=720; BPP=4
PIC=${1:-colorbars_1280x720.raw}
wr() { devmem $(printf "0x%08X" $((VDMA + $1))) 32 $(printf "0x%08X" $(($2))); }
rd() { devmem $(printf "0x%08X" $((VDMA + $1))) 32; }

[ -f "$PIC" ] || { echo "no $PIC"; exit 1; }
echo "copying $PIC to screen memory at $FB"
dd if="$PIC" of=/dev/mem bs=4096 seek=$((FB / 4096)) conv=notrunc 2>/dev/null || { echo "cannot write /dev/mem"; exit 1; }

echo "starting VDMA MM2S"
wr 0x00 0x4                    # MM2S_VDMACR: reset
sleep 1
wr 0x00 0x3                    # run (bit 0) + circular mode (bit 1): show the same frame again and again
wr 0x5C $FB                    # MM2S_START_ADDRESS1: frame buffer 1
wr 0x58 $((W * BPP))           # MM2S_FRMDLY_STRIDE: bytes from one line to the next
wr 0x54 $((W * BPP))           # MM2S_HSIZE: bytes per line
wr 0x50 $H                     # MM2S_VSIZE: lines; writing it starts the transfer
sleep 1
echo "MM2S_VDMACR = $(rd 0x00)   MM2S_VDMASR = $(rd 0x04)   (status bit 0 = halted, bits 4..6 = errors)"
