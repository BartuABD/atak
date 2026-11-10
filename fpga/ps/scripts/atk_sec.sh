#!/bin/sh
# atk_sec.sh - security of the A.T.A.K. PL server (atk_axi v9: AES-128-CCM secure envelope). Run as root:
#   sudo sh atk_sec.sh genkey            make a new random network key (atak_key on the SD card) and print it once:
#                                        the node firmware needs the same key (NET_KEY)
#   sudo sh atk_sec.sh setkey <32 hex>   use this key instead (e.g. the one in the node firmware)
#   sudo sh atk_sec.sh init              at boot (atak_boot.sh): key -> PL, downlink counter = saved + 256, the
#                                        saved mode back on. No key file: security stays off (plain, like v8).
#                                        PL v12 starts with SECURE_ONLY = 1: nothing is accepted until init has run
#   sudo sh atk_sec.sh mode <tx> <only>  SECURE_TX 0/1 (downlink encrypted), SECURE_ONLY 0/1 (plain uplink dropped);
#                                        saved, so it survives a reboot. Migration order (agreed with the nodes):
#                                        mode 0 0 -> nodes send secure -> mode 1 0 -> mode 1 1
#   sudo sh atk_sec.sh status            mode and the security counters
#   sudo sh atk_sec.sh save              write the downlink counter to the SD card now
#   sudo sh atk_sec.sh saver             loop: save the counter every 30 s when it changed (atak_boot.sh starts it)
# The downlink counter must NEVER repeat with the same key (the nodes would drop our frames as replays, and a
# repeated nonce breaks the encryption). Boot restores saved + 256; at most ~33 frames go out in 30 s, so it stays ahead.
# Note: the SD card is FAT, so file permissions cannot protect atak_key; keep the card (and root logins) safe.
BASE=0x40000000
SD=${ATK_SD:-/mnt/sd}
KEY=$SD/atak_key                 # 32 hex characters
CTR=$SD/dl_ctr                   # decimal
MODE=$SD/sec_mode                # 0..3 = SECURE_TX | SECURE_ONLY << 1
rd() { devmem $(printf "0x%08X" $((BASE + $1))) 32; }
wr() { devmem $(printf "0x%08X" $((BASE + $1))) 32 $(printf "0x%08X" $(($2))); }

id=$(( $(rd 0x000) )); [ $id -ge $((0x41544B09)) ] && [ $id -le $((0x41544B0C)) ] || { echo "atk_axi v9..v12 not found at $BASE (ID $(printf 0x%08X $id)): no security in this PL"; exit 1; }

keyhex() {      # the key file as 32 lowercase hex characters, or nothing if missing / bad
    [ -f $KEY ] || return
    k=$(tr -d ' \r\n\t' < $KEY | tr 'A-F' 'a-f')
    echo "$k" | grep -qE '^[0-9a-f]{32}$' && echo "$k"
}

savefile() {    # savefile <file> <text>: written safely (tmp + rename + sync)
    echo "$2" > $1.tmp && mv $1.tmp $1 && sync
}

forward() {     # forward <counter>: saved only if it is AHEAD of the saved value (never back, e.g. to 0 when no
                # key was loaded and the PL counter stayed 0)
    s=$(cat $CTR 2>/dev/null | tr -d '\r'); [ -n "$s" ] || s=0
    d=$(( ($1 - s) & 0xFFFFFFFF ))
    [ $d -gt 0 ] && [ $d -lt 2147483648 ] && savefile $CTR $1
}

load_key() {    # KEYi = key bytes 4i..4i+3 as a little-endian word
    k=$1; i=0
    while [ $i -lt 4 ]; do
        w=$(echo $k | cut -c$((8 * i + 1))-$((8 * i + 8)))
        b0=$(echo $w | cut -c1-2); b1=$(echo $w | cut -c3-4); b2=$(echo $w | cut -c5-6); b3=$(echo $w | cut -c7-8)
        wr $((0x08C + 4 * i)) 0x$b3$b2$b1$b0
        i=$((i + 1))
    done
}

case "$1" in
genkey)
    [ -n "$(keyhex)" ] && [ "$2" != "-f" ] && { echo "$KEY exists already (use 'genkey -f' to replace it: every node then needs the new key)"; exit 1; }
    # busybox od has no -A / -t / -N, head no -c: 16 random bytes (dd) as 8 hex words, the address column cut off
    k=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -x | head -1 | cut -d' ' -f2- | tr -d ' \n')
    echo "$k" | grep -qE '^[0-9a-f]{32}$' || { echo "ERROR: could not make a key (got '$k'); nothing saved"; exit 1; }
    savefile $KEY "$k"
    echo "new network key saved to $KEY:"
    echo "  $k"
    echo "give it to the node firmware (NET_KEY), then: sudo sh $0 init"
    ;;
setkey)
    k=$(echo "$2" | tr -d ' :' | tr 'A-F' 'a-f')
    echo "$k" | grep -qE '^[0-9a-f]{32}$' || { echo "need 32 hex characters (16 bytes)"; exit 1; }
    savefile $KEY "$k"
    echo "key saved to $KEY; load it with: sudo sh $0 init"
    ;;
init)
    k=$(keyhex)
    if [ -z "$k" ]; then
        wr 0x088 0
        echo "no key in $KEY: security off (plain frames, like v8). Make one with: sudo sh $0 genkey"
        exit 0
    fi
    load_key $k
    s=$(cat $CTR 2>/dev/null | tr -d '\r'); [ -n "$s" ] || s=0
    n=$(( (s + 256) & 0xFFFFFFFF ))
    wr 0x09C $n
    savefile $CTR $n                                     # saved at once: a crash before the next save is safe too
    m=$(cat $MODE 2>/dev/null | tr -d '\r'); [ -n "$m" ] || m=0
    wr 0x088 $(( 4 | (m & 3) ))                          # empty the replay table, then the saved mode
    echo "security: key loaded, downlink counter $n (saved $s + 256), mode TX=$((m & 1)) ONLY=$(((m >> 1) & 1))"
    ;;
mode)
    tx=${2:-0}; only=${3:-0}
    if [ "$tx" = 1 ] && [ -z "$(keyhex)" ]; then echo "no key: SECURE_TX needs one (genkey / setkey, then init)"; exit 1; fi
    m=$(( (tx & 1) | ((only & 1) << 1) ))
    wr 0x088 $m
    savefile $MODE $m
    echo "mode: SECURE_TX=$((m & 1)) SECURE_ONLY=$(((m >> 1) & 1)) (saved)"
    ;;
status)
    c=$(( $(rd 0x088) ))
    echo "SECURE_TX $((c & 1))  SECURE_ONLY $(((c >> 1) & 1))  key file: $([ -n "$(keyhex)" ] && echo yes || echo NO)"
    echo "downlink counter $(( $(rd 0x09C) ))  (saved $(cat $CTR 2>/dev/null))"
    echo "uplink:   secure ok $(( $(rd 0x0A0) ))  plain ok $(( $(rd 0x0A4) ))  plain dropped $(( $(rd 0x0A8) ))"
    echo "          MIC wrong $(( $(rd 0x0AC) ))  replays $(( $(rd 0x0B0) ))  relay dups $(( $(rd 0x0B4) ))$([ $id -ge $((0x41544B0B)) ] && echo "  relay upgrades $(( $(rd 0x0C8) ))")  E3 dropped $(( $(rd 0x0B8) ))  overruns $(( $(rd 0x0C4) ))"
    echo "downlink: secure sent $(( $(rd 0x0BC) ))  plain sent $(( $(rd 0x0C0) ))"
    ;;
save)
    forward $(( $(rd 0x09C) )) && echo "downlink counter $(cat $CTR) saved" || echo "not saved: the PL counter is not ahead of $CTR"
    ;;
saver)
    while true; do sleep 30; forward $(( $(rd 0x09C) )); done
    ;;
*)
    sed -n '2,13p' $0
    exit 1
    ;;
esac
