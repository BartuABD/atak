#!/bin/sh
# atk_cmds.sh - reads the 0xC1 command FIFO of the A.T.A.K. PL server (atk_axi v4) from Linux. Run as root:
#   sudo sh atk_cmds.sh            print the new commands and mark them as read (CMD_RD_COUNT = CMD_WR_COUNT)
#   sudo sh atk_cmds.sh peek       print the new commands but do not mark them as read
#   sudo sh atk_cmds.sh watch      keep printing new commands as they arrive (Ctrl+C to stop)
# FIFO entry k (64 entries) at 0x800 + 32*k: w0..w3 = 15 raw cmd_packet_t bytes, w4 = {SNR, RSSI}, w5 = now_s,
# w6 = sequence number. Command n is in entry n mod 64.
BASE=0x40000000
DEPTH=64
rd() { devmem $(printf "0x%08X" $((BASE + $1))) 32; }
wr() { devmem $(printf "0x%08X" $((BASE + $1))) 32 $(printf "0x%08X" $(($2))); }
s8() { v=$(( $1 & 0xFF )); [ $v -ge 128 ] && v=$((v - 256)); echo $v; }
s32() { v=$1; [ $v -ge 2147483648 ] && v=$((v - 4294967296)); echo $v; }
deg() { v=$1; a=$v; [ $a -lt 0 ] && a=$((-a)); s=""; [ $v -lt 0 ] && s="-"; printf "%s%d.%07d" "$s" $((a / 10000000)) $((a % 10000000)); }

id=$(( $(rd 0x000) )); [ $id -ge $((0x41544B04)) ] && [ $id -le $((0x41544B0C)) ] || { echo "atk_axi v4..v12 not found at $BASE"; exit 1; }

show_new() {    # show_new <mark 1|0>
    w=$(( $(rd 0x04C) )); r=$(( $(rd 0x050) )); now=$(( $(rd 0x038) ))
    # older than 64 entries back is already overwritten (cannot happen: the PL drops new ones when full)
    [ $((w - r)) -gt $DEPTH ] && r=$((w - DEPTH))
    while [ $r -lt $w ]; do
        o=$((0x800 + 32 * (r % DEPTH)))
        w0=$(( $(rd $o) )); w1=$(( $(rd $((o + 4))) )); w2=$(( $(rd $((o + 8))) )); w3=$(( $(rd $((o + 12))) ))
        w4=$(( $(rd $((o + 16))) )); t=$(( $(rd $((o + 20))) )); seq=$(( $(rd $((o + 24))) ))
        src=$(( (w0 >> 8) & 0xFFFF )); dst=$(( ((w0 >> 24) & 0xFF) | ((w1 & 0xFF) << 8) ))
        id=$(( (w1 >> 8) & 0xFF )); kind=$(( (w1 >> 16) & 0xFF ))
        lat=$(s32 $(( ((w1 >> 24) & 0xFF) | ((w2 & 0xFFFFFF) << 8) )))
        lon=$(s32 $(( ((w2 >> 24) & 0xFF) | ((w3 & 0xFFFFFF) << 8) )))
        case $kind in 1) k="POI";; 2) k="HAZARD";; 3) k="RALLY";; 4) k="COME HERE";; 5) k="HOLD HERE";; 6) k="CHECK AREA";; *) k="kind $kind";; esac
        to=$(printf "%04X" $dst); [ $dst -eq $((0xFFFF)) ] && to="ALL "
        if [ $(( w0 & 0xFF )) -eq $((0xC2)) ]; then        # delete request: [7..8] target_src, [9] target_msg_id
            tsrc=$(( ((w1 >> 24) & 0xFF) | ((w2 & 0xFF) << 8) )); tid=$(( (w2 >> 8) & 0xFF ))
            printf "  #%-4d %ds ago  from %04X  msg %3d  DELETE REQUEST for marker %04X / msg %d  rssi %d dBm  snr %d dB\n" \
                $seq $((now - t)) $src $id $tsrc $tid $(s8 $w4) $(s8 $((w4 >> 8)))
        else
        printf "  #%-4d %ds ago  from %04X to %s  msg %3d  %-10s  lat %s  lon %s  rssi %d dBm  snr %d dB\n" \
            $seq $((now - t)) $src "$to" $id "$k" "$(deg $lat)" "$(deg $lon)" $(s8 $w4) $(s8 $((w4 >> 8)))
        fi
        r=$((r + 1))
    done
    [ "$1" = 1 ] && wr 0x050 $w
}

case "$1" in
    peek)  show_new 0 ;;
    watch) while true; do show_new 1; sleep 1; done ;;
    "")    show_new 1
           echo "received $(( $(rd 0x04C) ))  overflows $(( $(rd 0x054) ))  dropped (address) $(( $(rd 0x05C) ))" ;;
    *)     sed -n '2,7p' "$0" ;;
esac
