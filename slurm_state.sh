#!/bin/bash

#monitor

OLD_SLURM_STATE=""
while true; do
	CURRENT_SLURM_STATE=$(sinfo -p all | grep -vE "alloc |mix |idle|comp|plnd")
	if [[ "$OLD_SLURM_STATE" != "$CURRENT_SLURM_STATE" ]]; then
		curl -d "$CURRENT_SLURM_STATE" ntfy.sh/kl_slurm_state
		OLD_SLURM_STATE="$CURRENT_SLURM_STATE"
	fi
	sleep 5m
done
