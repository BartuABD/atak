#!/bin/sh
# atk_wl.sh - manages the whitelist in the PL (atk_axi v4) at run time. Run as root:
#   sudo sh atk_wl.sh list               show all allowed node addresses
#   sudo sh atk_wl.sh add 157F           allow node 0x157F (written into the first free entry; 0x157F also works)
#   sudo sh atk_wl.sh del 157E           remove node 0x157E
#   sudo sh atk_wl.sh stale 60           nodes not heard for 60 s leave the downlink (0 = never)
#   sudo sh atk_wl.sh send               send the downlink table now
#   sudo sh atk_wl.sh save | restore     write the PL whitelist + stale time to the SD card / load them back
#   sudo sh atk_wl.sh set 0F53 1A2B      the whitelist becomes exactly these addresses (all others removed), saved
#   sudo sh atk_wl.sh clear              empty the location table (soft reset: table, counters, command FIFO;
#                                        the whitelist and the stale time stay)
# The PL starts from whitelist.mem at every power-up. add / del / stale also save to $SAVE on the SD card, and the
# boot script (atak_boot.sh) runs "restore", so the changes survive a power-off. No $SAVE yet: restore creates it.
BASE=0x40000000
ENTRIES=64
SD=${ATK_SD:-/mnt/sd}
SAVE=${ATK_WL_FILE:-$SD/whitelist.txt}                              # one hex address per line + a line "stale <s>"
rd() { devmem $(printf "0x%08X" $((BASE + $1))) 32; }
wr() { devmem $(printf "0x%08X" $((BASE + $1))) 32 $(printf "0x%08X" $(($2))); }
entry() { wr 0x040 $1; echo $(( $(rd 0x044) )); }          # WL_INDEX then WL_DATA

id=$(( $(rd 0x000) )); [ $id -ge $((0x41544B04)) ] && [ $id -le $((0x41544B0C)) ] || { echo "atk_axi v4..v12 not found at $BASE"; exit 1; }

find() {    # find <addr | -1 for a free entry>: prints the index or nothing
    i=0
    while [ $i -lt $ENTRIES ]; do
        e=$(entry $i)
        if [ "$1" -lt 0 ]; then [ $(( e & 0x10000 )) -eq 0 ] && { echo $i; return; }
        else [ $(( e & 0x10000 )) -ne 0 ] && [ $(( e & 0xFFFF )) -eq $1 ] && { echo $i; return; }; fi
        i=$((i + 1))
    done
}

save() {
    grep -q " $SD " /proc/mounts || { echo "SD card not mounted on $SD: not saved"; return; }
    {
        i=0
        while [ $i -lt $ENTRIES ]; do
            e=$(entry $i)
            [ $(( e & 0x10000 )) -ne 0 ] && printf "%04X\n" $(( e & 0xFFFF ))
            i=$((i + 1))
        done
        echo "stale $(( $(rd 0x03C) ))"
    } > $SAVE.tmp && mv $SAVE.tmp $SAVE && sync && echo "saved to $SAVE" || echo "ERROR: could not write $SAVE"
}

restore() {
    [ -f $SAVE ] || { echo "no $SAVE yet: saving the power-up whitelist"; save; return; }
    i=0
    while [ $i -lt $ENTRIES ]; do wr 0x040 $i; wr 0x044 0; i=$((i + 1)); done      # empty the PL whitelist
    i=0
    while read -r a b; do
        a=$(echo "$a" | tr -d '\r')
        case "$a" in
            stale) wr 0x03C $(echo "$b" | tr -d '\r') ;;
            [0-9A-Fa-f]*) [ $i -lt $ENTRIES ] && { wr 0x040 $i; wr 0x044 $(( 0x10000 | 0x$a )); i=$((i + 1)); } ;;
        esac
    done < $SAVE
    echo "restored $i addresses, stale after $(( $(rd 0x03C) )) s, from $SAVE"
}

hex() { h=${1#0x}; h=${h#0X}; echo $((0x$h)); }    # "0F53" or "0x0F53" -> number

case "$1" in
    list)
        i=0
        while [ $i -lt $ENTRIES ]; do
            e=$(entry $i)
            [ $(( e & 0x10000 )) -ne 0 ] && printf "  [%2d] %04X\n" $i $(( e & 0xFFFF ))
            i=$((i + 1))
        done
        echo "  stale after $(( $(rd 0x03C) )) s" ;;
    add)
        a=$(hex $2)
        [ -n "$(find $a)" ] && { echo "$2 is already allowed"; exit 0; }
        i=$(find -1); [ -z "$i" ] && { echo "whitelist full"; exit 1; }
        wr 0x040 $i; wr 0x044 $(( 0x10000 | a )); echo "allowed $2 (entry $i)"; save ;;
    del)
        i=$(find $(hex $2)); [ -z "$i" ] && { echo "$2 is not in the whitelist"; exit 1; }
        wr 0x040 $i; wr 0x044 0; echo "removed $2 (entry $i)"; save ;;
    stale)
        wr 0x03C $2; echo "stale after $(( $(rd 0x03C) )) s"; save ;;
    send)
        wr 0x004 1; echo "downlink sent" ;;
    set)
        shift; [ $# -eq 0 ] && { echo "usage: atk_wl.sh set <addr> [addr ...]"; exit 1; }
        i=0
        while [ $i -lt $ENTRIES ]; do wr 0x040 $i; wr 0x044 0; i=$((i + 1)); done
        i=0
        for a in "$@"; do wr 0x040 $i; wr 0x044 $(( 0x10000 | $(hex $a) )); i=$((i + 1)); done
        echo "whitelist = $*"; save ;;
    clear)
        wr 0x004 2; echo "location table, counters and command FIFO cleared (whitelist kept)" ;;
    save)    save ;;
    restore) restore ;;
    *)
        sed -n '2,13p' "$0" ;;
esac
