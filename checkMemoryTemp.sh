#include/17-cpu.sh
checkCpuType() {
    elif /sbin/dmidecode 2>/dev/null | grep -q 'AMD EPYC 9734';
        echo genoa768
}

#include/14-temperature.sh
checkMemoryTemperature() {
    if [[ $cpu == genoa768 ]]; then
        echo "$sensors" | grep -Eo 'CPU[0-9]+_DIMM[A-Z0-9]+_Temp,Temperature,[^,]+'  | \
            while read line; do 
                DIMM_POS=$(echo $line | grep -Eo "CPU[0-9]+_DIMM[A-Z0-9]+"); 
                DIMM_TEMP_VALUE=$(echo $line | awk -F ',' '{print int($3)}') ;
                _graphite="${GRAPHITE_HIERARCHY}.temperature.${DIMM_POS} ${DIMM_TEMP_VALUE} $(date '+%s')\n${_graphite}"
            done
    fi
}
