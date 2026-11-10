#!/bin/sh
# gui_start.sh - mounts the SD card's boot partition and starts the A.T.A.K. GUI from it. Run as root:
#   sudo sh /mnt/sd/gui_start.sh        (first time: sudo mkdir -p /mnt/sd && sudo mount /dev/mmcblk0p1 /mnt/sd)
mkdir -p /mnt/sd
grep -q " /mnt/sd " /proc/mounts || mount /dev/mmcblk0p1 /mnt/sd || exit 1
exec /mnt/sd/atak_gui /mnt/sd/map /mnt/sd/admin_msg_id
