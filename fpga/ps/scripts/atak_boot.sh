#!/bin/sh
# atak_boot.sh - lives on the SD card (/mnt/sd/atak_boot.sh); started at every power-up by /etc/init.d/atak-autostart.
# Makes the Zybo a standalone A.T.A.K. station (power + HDMI + mouse, no PC needed):
#   1. restores the whitelist and the stale time saved on the SD card (atk_wl.sh add / del / stale keep them saved)
#      and (PL v9) the security: network key, downlink counter, mode (atk_sec.sh)
#   2. keeps the HDMI GUI running: it is started again 3 s after it stops (Q key, crash)
# Log: /var/log/atak_boot.log.  Stop everything:  sudo /etc/init.d/atak-autostart stop
# Skip it at the next boot: rename this file on the SD card (e.g. to atak_boot.off).
SD=/mnt/sd
echo $$ > /var/run/atak_boot.pid
echo "atak_boot: $(date)"
sh $SD/atk_wl.sh restore
sh $SD/atk_sec.sh init                                  # v9: key, downlink counter (+256), saved security mode
sh $SD/atk_sec.sh saver &                               # v9: saves the downlink counter every 30 s
while true; do
    $SD/atak_gui $SD/map $SD/admin_msg_id
    echo "atak_gui stopped (exit $?), starting again in 3 s"
    sleep 3
done
