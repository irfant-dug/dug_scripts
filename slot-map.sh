#!/usr/bin/env bash
# slot-map.sh — map storcli drive slots to ZFS pool devices
# Usage: slot-map.sh [dm-uuid-mpath-<wwid>]
#   No arg: show all drives
#   With arg: show that drive + its individual multipath paths

STORCLI="/d/sw/3ware/storcli/opt/MegaRAID/storcli/storcli64"

if [[ ! -x "$STORCLI" ]]; then
    echo "ERROR: storcli not found at $STORCLI" >&2
    exit 1
fi

FILTER="${1#dm-uuid-mpath-}"  # strip prefix if present; empty = show all

# Build slot+pool table
table=$(gawk '
ARGIND == 1 {
    # zpool status: build device → pool map
    if (/pool:/)          { pool = $2 }
    if (/dm-uuid-mpath-/) { zp[$1] = pool }
    next
}
ARGIND == 2 {
    # multipathd: build wwid → dm-device map
    mp[$1] = $2
    next
}
ARGIND == 3 {
    # storcli /call /eall show: build ctrl:eid → enclosure name + slot count
    if (/^Controller = /)           { cur_ctrl = $3 }
    if (/^[ \t]*[0-9]+ +(OK|CRT|UNK|Optl)/) {
        eid    = $1 + 0
        nslots = $3 + 0
        prodid = (NF >= 11) ? $11 : $NF
        enc[cur_ctrl ":" eid]    = prodid
        eslots[cur_ctrl ":" eid] = nslots
        if (nslots > max_slots[cur_ctrl]) max_slots[cur_ctrl] = nslots
    }
    next
}
# ARGIND == 4: storcli wwn slot ctrl (deduped by wwn via sort)
!seen[$1]++ {
    hi   = substr($1, 1, 8)
    lo   = sprintf("%08x", strtonum("0x" substr($1, 9, 8)) - 3)
    wwid = "3" hi lo
    dev  = "dm-uuid-mpath-" wwid
    dm   = (wwid in mp) ? "/dev/" mp[wwid] : "?"
    pool = (dev  in zp) ? zp[dev]          : "?"
    split($2, s, ":")
    eid    = s[1]
    key    = $3 ":" eid
    encname = (key in enc) ? enc[key] : "enc"eid
    nslots  = (key in eslots) ? eslots[key] : 0
    pos     = (nslots == max_slots[$3]) ? "Top" : "Bottom"
    printf "%-42s  %-10s  Pool:%-10s  %-7s  Enc:%-12s  Slot:%s  Ctrl:c%s\n",
           dev, dm, pool, pos, encname, $2, $3
}
' \
    <(zpool status 2>/dev/null) \
    <(sudo multipathd show maps format "%w %d" 2>/dev/null | awk 'NR>1') \
    <(sudo "$STORCLI" /call /eall show 2>/dev/null) \
    <(
        for c in $(sudo "$STORCLI" /call show | awk '/^Controller/{print $3}'); do
            sudo "$STORCLI" /c"$c" /eall /sall show all \
            | awk -v ctrl="$c" '
                /^[0-9]+:[0-9]+/          { slot = $1 }
                /^(SAS Address|WWN) *= */ { w = tolower($NF); sub(/^0x/, "", w); print w, slot, ctrl }
            '
        done | sort
    ) \
| sort -t: -k2,2n -k3,3n)

if [[ -z "$FILTER" ]]; then
    echo "$table"
else
    # Show matching row
    match=$(echo "$table" | grep "dm-uuid-mpath-${FILTER}")
    if [[ -z "$match" ]]; then
        echo "ERROR: device not found: dm-uuid-mpath-${FILTER}" >&2
        exit 1
    fi
    echo "$match"
    echo

    # Show individual paths for this WWID
    echo "Paths:"
    sudo multipathd show paths format "%m %d %i %t %T" 2>/dev/null \
    | awk -v wwid="$FILTER" 'NR>1 && $1==wwid { printf "  %-8s  hcil:%-12s  dm-status:%-8s  path-status:%s\n", $2, $3, $4, $5 }'
fi
