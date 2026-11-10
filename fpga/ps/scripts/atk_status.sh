#!/bin/sh
# atk_status.sh - reads the A.T.A.K. PL server (atk_axi at 0x4000_0000, version 4) from Linux with busybox devmem and
# prints the counters and the location table. Run as root:  sudo sh atk_status.sh        (repeat every 2 s: ... 2)
# Register map: see rtl/atk_axi.v. Table entry i at 0x100 + 16*i: 12 raw bytes of pos_packet_t (little-endian) +
# word 3 = {age s [31:16], SNR [15:8], RSSI [7:0]}. Word 0 must be read first (it takes a consistent copy).
BASE=0x40000000
rd() { devmem $(printf "0x%08X" $((BASE + $1))) 32; }
s8() { v=$(( $1 & 0xFF )); [ $v -ge 128 ] && v=$((v - 256)); echo $v; }

show() {
    id=$(( $(rd 0x000) ))
    if [ $id -lt $((0x41544B04)) ] || [ $id -gt $((0x41544B0C)) ]; then echo "atk_axi v4..v12 not found at $BASE (ID $(printf 0x%08X $id))"; exit 1; fi
    n=$(( $(rd 0x008) )); fresh=$(( $(rd 0x048) )); stale=$(( $(rd 0x03C) ))
    echo "A.T.A.K. PL server   uptime $(( $(rd 0x038) )) s   nodes: $n   accepted: $(( $(rd 0x00C) ))   dropped (address): $(( $(rd 0x010) ))   crc errors: $(( $(rd 0x014) ))   downlinks sent: $(( $(rd 0x028) ))   stale after: ${stale} s"
    m=$fresh; nf=0; while [ $m -ne 0 ]; do nf=$((nf + (m & 1))); m=$((m >> 1)); done
    echo "next 0xD1 downlink: N = $nf  (fresh table entries; stale ones are left out)"
    echo "commands: received $(( $(rd 0x04C) ))   read by Linux $(( $(rd 0x050) ))   fifo overflows $(( $(rd 0x054) ))   accepted $(( $(rd 0x058) ))   dropped (address) $(( $(rd 0x05C) ))"
    if [ $id -ge $((0x41544B09)) ]; then
        c=$(( $(rd 0x088) ))
        echo "security: SECURE_TX $((c & 1)) SECURE_ONLY $(((c >> 1) & 1))   secure ok $(( $(rd 0x0A0) ))   plain ok $(( $(rd 0x0A4) ))   plain dropped $(( $(rd 0x0A8) ))   MIC wrong $(( $(rd 0x0AC) ))   replays $(( $(rd 0x0B0) ))   relay dups $(( $(rd 0x0B4) ))$([ $id -ge $((0x41544B0B)) ] && echo "   relay upgrades $(( $(rd 0x0C8) ))")   downlink ctr $(( $(rd 0x09C) ))"
    fi
    i=0
    while [ $i -lt $n ]; do
        o=$((0x100 + 16 * i))
        w0=$(( $(rd $o) )); w1=$(( $(rd $((o + 4))) )); w2=$(( $(rd $((o + 8))) )); w3=$(( $(rd $((o + 12))) ))
        addr=$(( w0 & 0xFFFF )); seq=$(( (w0 >> 16) & 0xFF ))
        lat=$(( ((w0 >> 24) & 0xFF) | ((w1 & 0xFFFFFF) << 8) ))
        lon=$(( ((w1 >> 24) & 0xFF) | ((w2 & 0xFFFFFF) << 8) ))
        flags=$(( (w2 >> 24) & 0xFF ))
        [ $lat -ge 2147483648 ] && lat=$((lat - 4294967296))      # signed 32 bit
        [ $lon -ge 2147483648 ] && lon=$((lon - 4294967296))
        rssi=$(s8 $w3); snr=$(s8 $((w3 >> 8))); age=$(( (w3 >> 16) & 0xFFFF ))
        state="LIVE "; [ $(( (fresh >> i) & 1 )) -eq 0 ] && state="STALE"
        printf "  [%2d] node %04X  %s  seq %3d  lat %d.%07d  lon %d.%07d  rssi %4d dBm  snr %3d dB  age %5d s  flags %02X\n" \
            $i $addr "$state" $seq $((lat / 10000000)) $(( (lat < 0 ? -lat : lat) % 10000000 )) \
            $((lon / 10000000)) $(( (lon < 0 ? -lon : lon) % 10000000 )) $rssi $snr $age $flags
        i=$((i + 1))
    done
}

if [ -n "$1" ]; then
    while true; do clear; show; sleep "$1"; done
else
    show
fi
