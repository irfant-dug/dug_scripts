#!/bin/bash

#Script to convert hpl analysis result into csv

LOG_DIR=${1:-.}

echo "hostname,gpu0,gpu1,gpu2,gpu3,gpu4,gpu5,gpu6,gpu7,performance"

ls -d1 $LOG_DIR/* | sort -V | while read line; do
	ls -d1 $line/* | grep analysis_result | tail -1 |
		while read file; do
			hostname=$(grep "Performance" "$file" | awk '{print $1}')
			performance=$(grep "Performance" "$file" | awk '{print $6,$7,$8}')

			gpu_values=""
			for i in $(seq 0 7); do
				gflops=$(grep -E "^ $i  \|" "$file" | awk -F'|' '{print $NF}')
				gpu_values="${gpu_values},${gflops}"
			done
			echo "${hostname}${gpu_values},${performance}"
		done
done
