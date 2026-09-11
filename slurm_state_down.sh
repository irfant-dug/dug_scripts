#!/bin/bash

#monitor

OLD_SLURM_STATE=""
while true; do
	CURRENT_SLURM_STATE=$(sinfo -p all -t down | sort -V)
	if [[ "$OLD_SLURM_STATE" != "$CURRENT_SLURM_STATE" ]]; then
		curl -d "$CURRENT_SLURM_STATE" ntfy.sh/kl_slurm_state
		OLD_SLURM_STATE="$CURRENT_SLURM_STATE"
	fi
	sleep 1m
done
