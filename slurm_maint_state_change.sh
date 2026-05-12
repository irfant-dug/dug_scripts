#!/bin/bash

MAINT_NODE=""
while true
do 
	QUERY=$(sinfo -p h200 | grep maint | awk '{print $6}');
	if [[ "$MAINT_NODE" != "$QUERY" ]]; then
		curl -d "$QUERY" ntfy.sh/slurm_maint_state_change
		MAINT_NODE="$QUERY"
	fi
	sleep 5m
done
