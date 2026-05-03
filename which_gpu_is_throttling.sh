#!/bin/bash

#take *gpu_temperature.log file as argument

#LOGFILE=$1

#if [ -z "$LOGFILE" ]; then
#	echo "Usage: $0 <logfile>_gpu_temperature.log"
#	exit 1
#fi

#accept more than 2 logs
if [ $# -eq 0 ]; then
	echo "Usage: $0 <logfile1>_gpu_temperature.log [logfile2 ...]"
	exit 1
fi

#echo "GPU | Serial Number | HW_THERM | SW_THERM | HW_SLOW  | GPU_TEMP | MEM_TEMP"
echo "GPU | Serial Number | BUS_ID | HW_THERM | SW_THERM | HW_SLOW | GPU_MAXTEMP | MEM_MAXTEMP"
echo "-----------------------------------------------------------------------------------------"

awk -F', ' '
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
            printf " %d  | %-13s | %6s | %8d | %8d | %7d | %11d | %11d\n", i, sn, trim_bus[2], hw[sn], sw[sn], hs[sn], max_gpu_temp[sn], max_mem_temp[sn]
        }
    }
}' "$@"
