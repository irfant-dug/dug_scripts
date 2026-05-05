#!/bin/bash
#this scripts will run in it-kl and it-houston
#this scripts will check for nodes that goes to maint state, pdsh into the node, run HPL, and release the node from reservation

RESERVATION="#317966 hpl test"
MAINT_NODE=""

while true; do
	QUERY=$(
		scontrol show ReservationName="${RESERVATION}" | grep Nodes | awk '{print $1}' | sed 's/Nodes=//' |
			xargs -I {} scontrol show hostname {} | tr '\n' ',' | sed 's/,$/\n/' | xargs -I {} sinfo -p h200 -n {} | grep maint | awk '{print $6}' |
			xargs -I {} scontrol show hostname {} | tr '\n' ',' | sed 's/,$/\n/'
	)
	if [[ "$MAINT_NODE" != "$QUERY" ]]; then
		curl -d "$QUERY" ntfy.sh/slurm_maint_state_change_houston
		MAINT_NODE="$QUERY"

		#if there is no node in Maintenance State, do nothing
		if [ -z "$QUERY" ]; then
			sleep 5m
			continue
		fi

		pdsh -w "${QUERY}" '/d/admin/scripts/hpl_thorough_run.sh'
		EXCLUDE=$(echo $QUERY | tr ',' '|')

		REMAINING_NODE=$(scontrol show ReservationName="${RESERVATION}" | grep Nodes | awk '{print $1}' | sed 's/Nodes=//' | xargs -I {} scontrol show hostname {} | grep -Ev $EXCLUDE | tr '\n' ',' | sed 's/,$/\n/')

		if [ -n "$REMAINING_NODE" ]; then
			scontrol update ReservationName="${RESERVATION}" Nodes=$REMAINING_NODE
		else
			curl -d "HPL Run Done" ntfy.sh/slurm_maint_state_change_houston
			scontrol delete ReservationName="${RESERVATION}"
			break
		fi

	fi
	sleep 5m
done
