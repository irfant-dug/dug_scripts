#!/bin/bash

NODE_DATE=$1

if [ -z "$NODE_DATE" ]; then
	echo "Usage: $0 <hostname_date_time>"
	echo "Example: $0 /data/kl7/dug/IT/h200_hpl/logs/hpl_run_202605/knod2-8-19/knod2-8-19_20260503_151203"
	exit 1
fi

echo "GPU | Serial Number | BUS_ID | HW_THERM | SW_THERM | HW_SLOW | GPU_MAXTEMP | MEM_MAXTEMP |    GFLOPS   "
echo "-----------------------------------------------------------------------------------------------------"

GPU=$(ls -1 ${NODE_DATE}* | grep -Eo "${NODE_DATE}_GPU[0-9]+" | uniq | sort)

for i in $GPU; do
	GPU_GFLOPS=$(cat "${i}_nvidia_hpl.txt" | grep WC0 | tail -1 | awk '{print $7}')

	awk -v GPU_GFLOPS="$GPU_GFLOPS" -F', ' '
  {
      idx = $1
      sn  = $2
  
      #add bus_id
      bus_id[sn] = $3
  
      #if hwts,swts,hws for a serial is active, do increment
      hw[sn] += ($8  == "Active" ? 1 : 0)
      sw[sn] += ($9  == "Active" ? 1 : 0)
      hs[sn] += ($10 == "Active" ? 1 : 0)
  
      #if current gpu/mem temp is higher than the max gpu/mem temp, it become the max gpu/mem temp
      max_gpu_temp[sn] = ($4 >= max_gpu_temp[sn] ? $4 : max_gpu_temp[sn])
      max_mem_temp[sn] = ($5 >= max_mem_temp[sn] ? $5 : max_mem_temp[sn])
  
      # Map index to serial
      serial[idx] = sn
  }
  END {
      for (i=0; i<=7; i++) {
          sn = serial[i]
          split(bus_id[sn], trim_bus, ":")
          if (sn != "") {
              printf " %d  | %-13s | %6s | %8d | %8d | %7d | %11d | %11d | %-9s\n", i, sn, trim_bus[2], hw[sn], sw[sn], hs[sn], max_gpu_temp[sn], max_mem_temp[sn], GPU_GFLOPS
          }
      }
  }' "${i}_gpu_temperature.txt"

done

echo $NODE_DATE | grep -Eo "[a-z]+nod[0-9-]+" | uniq | xargs -I {} echo -e "\n{} Performance (GFLOPS) (per GPU): $(cat "${NODE_DATE}_nvidia_hpl.txt" | grep WC0 | awk '{print $7,$8,$9}')"
