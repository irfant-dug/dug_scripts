#!/bin/bash
#Given a reservation have reserved many nodes in advanced,
#this scripts release the remaining nodes when N nodes have gone into maint state

RESERVATION="#317966 applying graphite 1"
N=3

while true; do
	#get the nodes in the reservation that are in maint state
	QUERY=$(
		scontrol show ReservationName="${RESERVATION}" | grep Nodes | awk '{print $1}' | sed 's/Nodes=//' |
			xargs -I {} scontrol show hostname {} | tr '\n' ',' | sed 's/,$/\n/' | xargs -I {} sinfo -p h200 -n {} | grep maint | awk '{print $6}' |
			xargs -I {} scontrol show hostname {}
	)
	NUMBER_OF_MAINT_NODES=$(echo -e "$QUERY" | grep -v '^$' | wc -l)
	echo -e "$QUERY"
	if [[ "$NUMBER_OF_MAINT_NODES" -ge 3 ]]; then

		LEFT=$(echo -e "$QUERY" | head -n "$N" | tr '\n' ',' | sed 's/,$/\n/')
		echo "$LEFT"
		scontrol update ReservationName="${RESERVATION}" nodes=$LEFT

		#break when more than N nodes are reserved
		break
	fi
	sleep 5m
done
