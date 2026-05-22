#!/bin/bash
#Given a reservation have reserved many nodes in advanced,
#this scripts release the remaining nodes when N nodes have gone into maint state

#RESERVATION="#317966 applying graphite 1"
#N=3

RESERVATION="${1}"
N=$2

if [[ -z "$RESERVATION" && -z "$N" ]]; then
	echo "Usage: $0 <hostname_date_time>"
	echo "Example: $0 /data/kl7/dug/IT/h200_hpl/logs/hpl_run_202605/knod2-8-19/knod2-8-19_20260503_151203"
	exit 1
fi

while true; do
	#get the nodes in the reservation that are in maint state
	QUERY=$(
		scontrol show ReservationName="${RESERVATION}" | grep Nodes | awk '{print $1}' | sed 's/Nodes=//' |
			xargs -I {} scontrol show hostname {} | tr '\n' ',' | sed 's/,$/\n/' | xargs -I {} sinfo -p all -n {} | grep maint | awk '{print $6}' |
			xargs -I {} scontrol show hostname {}
	)
	NUMBER_OF_MAINT_NODES=$(echo -e "$QUERY" | grep -v '^$' | wc -l)
	echo -e "$QUERY"
	if [[ "$NUMBER_OF_MAINT_NODES" -ge "$N" ]]; then

		LEFT=$(echo -e "$QUERY" | head -n "$N" | tr '\n' ',' | sed 's/,$/\n/')
		echo "$LEFT"
		scontrol update ReservationName="${RESERVATION}" nodes=$LEFT

		#break when more than N nodes are reserved
		break
	fi
	sleep 2m
done
