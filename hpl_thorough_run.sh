#!/bin/bash
#This script is meant to run on KL only
#The purpose of this script is to get per node and per GPU HPL result
#and analyze which gpu is throttling

cd /data/kl7/dug/IT/h200_hpl
module load apptainer cuda/13.1
mkdir -p /tmp/hpl
sudo chmod 770 /tmp/hpl #avoid hpl from breaking if dir exist and no g+rw
export APPTAINERENV_TMPDIR="/tmp/hpl"

#create a node dir for the node results
mkdir -p /data/kl7/dug/IT/h200_hpl/logs/hpl_run_202605/${HOSTNAME}
DATE=$(date +%Y%m%d_%H%M%S)

#run 8 GPU HPL
echo "Running 8-GPUs HPL"
apptainer run --nv -B /d/sw/cuda,/tmp/hpl /data/kl7/dug/IT/h200_hpl/hpc-benchmarks_26.02.sif mpirun -np 8 /workspace/hpl.sh --dat /workspace/hpl-linux-x86_64/sample-dat/HPL-H200-8GPUs.dat --no-multinode --gpu-affinity 0:1:2:3:4:5:6:7 |
	tee /data/kl7/dug/IT/h200_hpl/logs/hpl_run_202605/${HOSTNAME}/${HOSTNAME}_${DATE}_nvidia_hpl.txt &
HPL_PID=$!
#while the HPL is running, log its temperature and throttle status metrics
while kill -0 $HPL_PID 2>/dev/null; do
	nvidia-smi --query-gpu=index,serial,pci.bus_id,temperature.gpu,temperature.memory,power.draw,power.limit,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_thermal_slowdown,clocks_throttle_reasons.hw_slowdown --format=csv,noheader |
		tee -a /data/kl7/dug/IT/h200_hpl/logs/hpl_run_202605/${HOSTNAME}/${HOSTNAME}_${DATE}_gpu_temperature.txt >/dev/null
	sleep 1s
done

#run HPL on each GPU
for i in $(seq 0 7); do
	echo "Running GPU${i} HPL"
	echo -e "--------------------\n"
	apptainer run --nv -B /d/sw/cuda,/tmp/hpl /data/kl7/dug/IT/h200_hpl/hpc-benchmarks_26.02.sif mpirun -np 1 /workspace/hpl.sh --dat /data/kl7/dug/IT/h200_hpl/HPL-H200-1GPU.dat --no-multinode --gpu-affinity $i |
		tee /data/kl7/dug/IT/h200_hpl/logs/hpl_run_202605/${HOSTNAME}/${HOSTNAME}_${DATE}_GPU${i}_nvidia_hpl.txt &
	HPL_PID=$!
	while kill -0 $HPL_PID 2>/dev/null; do
		nvidia-smi --id=$i --query-gpu=index,serial,pci.bus_id,temperature.gpu,temperature.memory,power.draw,power.limit,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_thermal_slowdown,clocks_throttle_reasons.hw_slowdown --format=csv,noheader |
			tee -a /data/kl7/dug/IT/h200_hpl/logs/hpl_run_202605/${HOSTNAME}/${HOSTNAME}_${DATE}_GPU${i}_gpu_temperature.txt >/dev/null
		sleep 1s
	done
done

#run analysis and generate report
/d/admin/scripts/hpl_log_analysis.sh /data/kl7/dug/IT/h200_hpl/logs/hpl_run_202605/${HOSTNAME}/${HOSTNAME}_${DATE} |
	tee /data/kl7/dug/IT/h200_hpl/logs/hpl_run_202605/${HOSTNAME}/${HOSTNAME}_${DATE}_analysis_result.txt
