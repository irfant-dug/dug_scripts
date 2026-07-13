#!/cluster/bin/bash
# -*- mode: sh; tab-width: 4; indent-tabs-mode: nil; -*-
# vim: set expandtab shiftwidth=4 softtabstop=4 ts=4 :

checkTemperatureRecord() {
    dbg $*
    if [[ -f /etc/logrotate.d/temperature_record ]] && ! pgrep -f /d/admin/scripts/temperature_record.sh > /dev/null; then
        report_warn 'Daemons' 'Must restart temperature recorder - nohup /d/admin/scripts/temperature_record.sh & > /dev/null 2>&1'
    fi
}

checkTemperature() {
    dbg $*
    
    disable_shutoff=/cluster/var/state/disable_shutoff
    _templog=
    _graphite=
    _throttle=0
    _warn=0
    _crit=0
    
    # If we are in air we offset a decent amount defined by ${AIR_TEMP_OFFSET}. If we are in DF then we wouldn't offset, but
    # we should offset by at least a degree to allow us to requeue jobs; this is defined by ${CRITICAL_SHUTOFF_OFFSET}
    [[ -z $MONITOR_DIFLU ]] && _offset=$AIR_TEMP_OFFSET || _offset=$CRITICAL_SHUTOFF_OFFSET

    # Try to get the IPMI sensor info
    grep -qE 'model name[[:space:]]:\ Intel\(R\)\ Xeon\(R\)\ CPU\ Max\ 9480' /proc/cpuinfo || sensors=$(getInfoIPMI)

    # #87809 just run the power check on every machine; it will lock out the check if it cannot run it
    getPowerIPMI
    PATH=$PATH:/bin:/usr/bin

    #169537 Add CPU frequency info to help with investigating thermal issues
    cpu_freq=$(</proc/cpuinfo awk '/MHz/ {print $4}' | awk '{sum+=$1} END { print int(sum/NR)}')

    # Disabling high-cpu temperature trigger for shutting down nodes running on Cascade lake CPUs
    # also disabling it for AMD Genoas and Bergamos
    if grep -qE 'model name[[:space:]]:.*Xeon.*[[:alpha:]][[:space:]]+[86543]2[0-9]{2,2}|model name[[:space:]]+: AMD EPYC (9734|9654|9684)' /proc/cpuinfo; then
        touch $disable_shutoff
    fi

    # Select the appropriate checks here; these checks will aggregate their data in _templog and flag warnings/criticals as needed.
    # All checks should append their output to _templog and if necessary set _warn and _crit to flag a warning or a critical for the
    # overall temperature service check.

    # Check CPU temperature on any machine with preference to using IPMI
    checkKNL
    if ! [[ "$not_knl" ]]; then
        checkCpuTempKNL
        checkMotherBoardTempKNL
    elif grep -qE 'model name[[:space:]]:\ Intel\(R\)\ Xeon\(R\)\ CPU\ Max\ 9480' /proc/cpuinfo; then
	checkCpuTempIPMISPR
    elif [[ -z $sensors ]] || ! { checkCpuTempIPMI || checkCpuTempMarginIPMI; }; then
        grep -qE '^model name.+Intel.+$' '/proc/cpuinfo' && checkCpuTempIntel || checkCpuTempAMD
    fi

    # Check System temperature on machines that should have IPMI
    # when a node is in diflu we don't care what its exit temp is
    [[ -n $sensors ]] && { checkSysTempIPMI; (( MONITOR_DIFLU != 1 )) && checkExitTempIPMI; checkPdbTempIPMI; }

    # I think this is the best place to run this
    # Simply reports inlet temp if it exists
    if echo "$sensors" | grep -q ",Inlet Temp,"; then
	checkInletTempIPMI
    fi

    # If this is a MegaRAID or 3ware server check BBU temperature
    # #90724 monitor disk temperatures via SMART values on all machines where possible
    if [[ -e /dev/megaraid_sas_ioctl_node ]]; then
        checkMegaBbuTemp
        checkDiskTempMegaRaid
    elif [[ -e /dev/twa0 ]]; then
        check3wareBbuTemp
        checkDiskTemp3ware
    else
        checkDiskTemp
    fi
    HAS_READY_PHI=0
    MPSS_READY_FILE="/dev/shm/completed_rc.local.mpss"
    if [[ $MONITOR_PHI -gt 0 ]] && [[ ! -f $MPSS_READY_FILE  ]]; then
	HAS_READY_PHI=1
        return
    fi

    # Check Phi temperature on machines with Phis and check speed where relevant
    (( HAS_READY_PHI > 0 )) && checkPhiTemp
    [[ $NODETYPE == DESKTOP ]] && (( HAS_READY_PHI > 0 )) && getPhiFanSpeed

    # #79424 check for Nvidia GPU temp anywhere
    [[ $NODETYPE == DESKTOP ]] && checkGpuTemp

    # Now check for throttling; any of the above temperature checks may have also flagged _throttle=1
    # N.B. this flag is the only way to throttle on a non-compute node (they work anywhere)
    [[ -f /.slowCpu ]] && _throttle=1
    { (( _throttle )) && [[ ! -f "$disable_shutoff" ]]; } && throttleCPU slow || throttleCPU fast

    #IT-7287 Log Genoa DIMM Temperature Metrics to Graphite
    cpu=$(checkCpuType)
    if [[ $cpu == genoa768 ]]; then
        while read line; do
            DIMM_POS=$(echo "$line" | grep -Eo "CPU[0-9]+_DIMM[A-Z0-9]+");
            DIMM_TEMP_VALUE=$(echo "$line" | awk -F ',' '{print int($3)}') ;
            if [[ $DIMM_TEMP_VALUE -ne 0 ]]; then
                _graphite="${GRAPHITE_HIERARCHY}.temperature.${DIMM_POS} ${DIMM_TEMP_VALUE} $(date '+%s')\n${_graphite}"
            fi
        done < <(echo "$sensors" | grep -Eo 'CPU[0-9]+_DIMM[A-Z0-9]+_Temp,Temperature,[^,]+')
    fi
        
    # If we have any graphite data to report let's do that now
    [[ -n $_graphite ]] && toGraphite "${_graphite%%\\n}"

    # If we got no data from the checks then that's unfortunate but not fatal, so get out
    [[ -z $_templog ]] && report_ok Temperature 'Could not detect any temperatures' && return 0

    # If we've gotten this far but disabled shutoff let's give a warning
    [[ -f "$disable_shutoff" ]] &&
    append _templog "$disable_shutoff is present so NOT throttling or shutting off even during severe temperatures" &&
    #_warn=1

    # Make sure the temperature message gets reported and logged (report_ok doesn't get logged so manually do it there)
    _templog="${_templog# }"
    if (( _crit )); then
        report_fail Temperature "$_templog"
    elif (( _warn )); then
        report_warn Temperature "$_templog"
    else
        log "Temperature: ${_templog}"
        report_ok Temperature "$_templog"
    fi

    return 0

}

checkMotherBoardTempKNL() {
    dbg $*
    BBInletTemp=0
    BMCTemp=0
    BBP1VRTemp=0
    BBMemVRTemp=0
    PS1Temperature=0
    PS2Temperature=0
    P1ThermalCtrl=0

    reading="$(timeout -s 9 5 /cluster/sbin/ipmi-sensors -Q --sdr-cache-directory=/cluster/var/spool --sdr-cache-recreate --comma-separated-output --no-header-output --non-abbreviated-units --output-sensor-thresholds 2>/dev/null)"

    BBInletTemp=$(grep BB\ Inlet\ Temp <<< "${sensors}" | awk -F "," '{ print int($4) }')
    BMCTemp=$(grep BMC\ Temp <<< "${sensors}" | awk -F "," '{ print int($4) }')
    BBP1VRTemp=$(grep BB\ P1\ VR\ Temp <<< "${sensors}" | awk -F "," '{ print int($4) }')
    BBMemVRTemp=$(grep BB\ Mem\ VR\ Temp <<< "${sensors}" | awk -F "," '{ print int($4) }')
    PS1Temperature=$(grep PS1\ Temperature <<< "${sensors}" | awk -F "," '{ print int($4) }')
    PS2Temperature=$(grep PS2\ Temperature <<< "${sensors}" | awk -F "," '{ print int($4) }')
    P1ThermalCtrl=$(grep P1\ Therm\ Ctrl\ \% <<< "${reading}" | awk -F "," '{ print int($4) }')

    mb_message=""

    [[ -n ${BBInletTemp} ]] && mb_message="InTemp=${BBInletTemp}" && _graphite="${GRAPHITE_HIERARCHY}.temperature.mbInTemp ${BBInletTemp} $(date '+%s')\n${_graphite}"
    [[ -n ${BMCTemp} ]] && mb_message="${mb_message} OutTemp=${BMCTemp}" && _graphite="${GRAPHITE_HIERARCHY}.temperature.mbOutTemp ${BMCTemp} $(date '+%s')\n${_graphite}"
    [[ -n ${BBP1VRTemp} ]] && mb_message="${mb_message} VRTemp=${BBP1VRTemp}" && _graphite="${GRAPHITE_HIERARCHY}.temperature.mbVRTemp ${BBP1VRTemp} $(date '+%s')\n${_graphite}"
    [[ -n ${BBMemVRTemp} ]] && mb_message="${mb_message} MemTemp=${BBMemVRTemp}" && _graphite="${GRAPHITE_HIERARCHY}.temperature.mbMemTemp ${BBMemVRTemp} $(date '+%s')\n${_graphite}"
    [[ -n ${PS1Temperature} ]] && mb_message="${mb_message} PS1Temp=${PS1Temperature}" && _graphite="${GRAPHITE_HIERARCHY}.temperature.PS1Temp ${PS1Temperature} $(date '+%s')\n${_graphite}"
    [[ -n ${PS2Temperature} ]] && mb_message="${mb_message} PS2Temp=${PS2Temperature}" && _graphite="${GRAPHITE_HIERARCHY}.temperature.PS2Temp ${PS2Temperature} $(date '+%s')\n${_graphite}"
    [[ -n ${P1ThermalCtrl} ]] && mb_message="${mb_message} %Throttle=${P1ThermalCtrl}" && _graphite="${GRAPHITE_HIERARCHY}.temperature.Throttle ${P1ThermalCtrl} $(date '+%s')\n${_graphite}"

    [[ -n "${cpu_message}" ]] && append _templog "$mb_message" || return 1
}

checkCpuTempKNL() {
    dbg $*
    bad_state_cpu_coretemp=/cluster/var/state/no_cpu_temperatures_coretemp
    
    [[ $(strike ${bad_state_cpu_coretemp} check) == out ]] && return 1

    # Make sure we have coretemp loaded unless we've already tried and failed to either load it or find any useful information from it
    ! grep -q coretemp /proc/modules && modprobe coretemp 2>/dev/null
    ! grep -q coretemp /proc/modules && strike "$bad_state_cpu_coretemp" out && return 1

    # Check to see if we have a Physical id n ('package') temperature sensor - if not check to see if we can average the core temperatures
    temps=
    crits=
    declare -A labels
    i=0
    
    for cpu in /sys/class/hwmon/hwmon*/device/hwmon/hwmon*; do
        [[ ! -d "$cpu" ]] && log 'Found no CPU temperatures from coretemp; declaring sensors as faulty for CPU temperatures from coretemp' && strike "$bad_state_cpu_coretemp" out && return 1
        labels[${i}]="$(</dev/null grep -l 'Core ' $cpu/temp*_label 2>/dev/null)"
        if [[ -z "${labels[${i}]}" ]]; then
            # No direct CPU temperature readouts, so see if data about individual cores is available
            labels[${i}]="$(</dev/null grep -l 'Core ' $cpu/temp*_label 2>/dev/null)"
        fi
        [[ -z "${labels[${i}]}" ]] || (( i++ ))
    done
    [[ -z "${labels[0]}" ]] && log 'Found no Physical id temps or core temps from coretemp; declaring sensors as faulty for CPU temperatures from coretemp' && strike "$bad_state_cpu_coretemp" out && return 1

    # We've found something to read; whether it's individual cores or the CPUs directly try to average them and compare to the minimum critical
    cpu_message=
    for (( j=0; j<i; j++ )); do
        for temp in ${labels[${j}]}; do
            t="${temp%%_label}_input"
            [[ -f "${t}" ]] && temps="${t} ${temps}" 
        done
        temp_avg="$(</dev/null awk '{sum+=$1;count++}END{if(count>0){print int(sum/count/1000)}}' ${temps})"

        [[ -f "$bad_state_cpu_coretemp" ]] && rm -f "$bad_state_cpu_coretemp"
        cpu_message="${cpu_message},${temp_avg}"
        _graphite="${GRAPHITE_HIERARCHY}.temperature.cpu${j} ${temp_avg} $(date '+%s')\n${_graphite}"
    done

    { [[ -n "$cpu_message" ]] && append _templog "cpu=${cpu_message#,}"; } &&
    { append _templog "cpu_freq=${cpu_freq}"; } || return 1

    return 0
}

checkCpuTempIntel() {
    dbg $*
    bad_state_cpu_coretemp=/cluster/var/state/no_cpu_temperatures_coretemp

    [[ $(strike ${bad_state_cpu_coretemp} 'check') == out ]] && return 1

    # This CPU model is unsupported by our coretemp module version and it gives bogus readings
    if grep -qE '^model name[[:space:]]+: Intel\(R\) Xeon\(R\) CPU E5\-2630L v2 @ 2.40GHz$' '/proc/cpuinfo'; then
        strike "${bad_state_cpu_coretemp}" 'out'
        return 1
    fi

    # Make sure we have coretemp loaded unless we've already tried and failed to either load it or find any useful information from it
    ! grep -q coretemp /proc/modules && modprobe coretemp 2>/dev/null
    ! grep -q coretemp /proc/modules && strike "$bad_state_cpu_coretemp" out && return 1

    # Check to see if we have a Physical id n ('package') temperature sensor - if not check to see if we can average the core temperatures
    declare -A labels
    local i=0 temps= crits=

    for cpu in /sys/class/hwmon/hwmon*; do
        [[ ! -d "$cpu" ]] && log 'Found no CPU temperatures from coretemp; declaring sensors as faulty for CPU temperatures from coretemp' && strike "$bad_state_cpu_coretemp" out && return 1
        anyexist $cpu/device/temp*_label || continue  # this is needed cause the grep below can hang waiting on input
        
        labels[$i]=$(grep -l 'Physical id ' $cpu/device/temp*_label 2>/dev/null)
        if [[ -z ${labels[$i]} ]]; then
            # No direct CPU temperature readouts, so see if data about individual cores is available
            labels[${i}]="$(grep -l 'Core ' $cpu/device/temp*_label 2>/dev/null)"
        fi
        [[ -z ${labels[$i]} ]] || (( i++ ))
    done
    [[ -z ${labels[0]} ]] && log 'Found no Physical id temps or core temps from coretemp; declaring sensors as faulty for CPU temperatures from coretemp' && strike "$bad_state_cpu_coretemp" 'out' && return 1

    # We've found something to read; whether it's individual cores or the CPUs directly try to average them and compare to the minimum critical
    local cpu_message=
    for (( j=0; j<i; j++ )); do
        for temp in ${labels[$j]}; do
            t=${temp%%_label}_input
            c=${temp%%_label}_crit
            [[ -f "$t" ]] && temps="$t $temps" 
            [[ -f "$c" ]] && crits="$c $crits" 
        done
        temp_crit=$(sort -n $crits | awk 'NR==1{print int($1/1000)}')
        temp_avg=$(awk '{sum+=$1;count++}END{if(count>0){print int(sum/count/1000)}}' $temps)

        # Sanity check on the values - current checks are just educated guesses
        if [[ -z $temp_avg || -z $temp_crit ]] || (( temp_avg < 5 || temp_avg > 150 || temp_crit < 50 || temp_crit > 120 )); then
            log "Found CPU temperature of $temp_avg and critical temperature of $temp_crit from coretemp; declaring sensors as faulty"
            strike "$bad_state_cpu_coretemp"
            return 1
        else
            [[ -f "$bad_state_cpu_coretemp" ]] && rm -f "$bad_state_cpu_coretemp"
            if (( temp_avg >= temp_crit - 10 && temp_avg < temp_crit - 5 )); then
                cpu_message=${cpu_message:+${cpu_message},}$temp_avg"(SHUTOFF@${temp_crit})"
            elif (( temp_avg >= temp_crit - 5 )); then
                [[ $NODETYPE == COMPUTE ]] && _throttle=1
                cpu_message=${cpu_message:+${cpu_message},}$temp_avg"(SHUTOFF@${temp_crit})"
                _crit=1
            else
                cpu_message=${cpu_message:+${cpu_message},}$temp_avg
            fi
            _graphite="${GRAPHITE_HIERARCHY}.temperature.cpu$j $temp_avg $(date '+%s')\n$_graphite"
        fi
    done

    { [[ -n "$cpu_message" ]] && append _templog "cpu=${cpu_message#,}"; } &&
    { append _templog "cpu_freq=${cpu_freq}"; } || return 1

    return 0

}

checkCpuTempAMD() {
    dbg $*
    bad_state_cpu_k10temp='/cluster/var/state/no_cpu_temperatures_k10temp'

    [[ "$(strike ${bad_state_cpu_k10temp} 'check')" == 'out' ]] && return 1

    # Make sure we have k10temp loaded unless we've already tried and failed to either load it or find any useful information from it
    ! grep -q 'k10temp' '/proc/modules' && modprobe 'k10temp' 2>/dev/null
    ! grep -q 'k10temp' '/proc/modules' && strike "${bad_state_cpu_k10temp}" 'out' && return 1

    # The k10temp module should create entries in /sys/class/hwmon/hwmonX/device/temp1_* and for the actual CPUs there should be temp1_crit
    cpu_message=
    i=0
    for cpu in /sys/class/hwmon/hwmon*/device/temp1_crit; do
        [[ ! -s "${cpu}" ]] && log 'Found no CPU temperatures from k10temp; declaring sensors as faulty for CPU temperatures from k10temp' && strike "${bad_state_cpu_k10temp}" 'out' && return 1
        <"${cpu%/*}/temp1_input" read -r cpu_temp
        <"${cpu}" read -r cpu_temp_max
        cpu_temp="$(( cpu_temp / 1000 ))"
        cpu_temp_max="$(( cpu_temp_max / 1000 ))"
        if ! [[ "${cpu_temp}" =~ ^[0-9]+$ && "${cpu_temp_max}" =~ ^[0-9]+$ ]] ||
             (( cpu_temp < 5 || cpu_temp > 150 || cpu_temp_max < 50 || cpu_temp_max > 120 )); then
            log "Found CPU temperature of ${cpu_temp} and critical temperature of ${cpu_temp_max} from k10temp; declaring sensors as faulty"
            strike "${bad_state_cpu_k10temp}"
            return 1
        else
            [[ -f "${bad_state_cpu_k10temp}" ]] && rm -f "${bad_state_cpu_k10temp}"
            if (( cpu_temp >= cpu_temp_max - 10 && cpu_temp < cpu_temp_max - 5 )); then
                cpu_message="${cpu_message},${cpu_temp}(SHUTOFF@${cpu_temp_max})"
            elif (( cpu_temp >= cpu_temp_max - 5 )); then
                [[ "${NODETYPE}" == 'COMPUTE' ]] && _throttle=1
                cpu_message="${cpu_message},${cpu_temp}(SHUTOFF@${cpu_temp_max})"
                _crit=1
            else
                cpu_message="${cpu_message},${cpu_temp}"
            fi
            _graphite="${GRAPHITE_HIERARCHY}.temperature.cpu${i} ${cpu_temp} $(date '+%s')\n${_graphite}"
            (( i++ ))
        fi
    done

    { [[ -n "$cpu_message" ]] && append _templog "cpu=${cpu_message#,}"; } &&
    { append _templog "cpu_freq=${cpu_freq}"; } || return 1

    return 0

}

checkCpuTempIPMI() {
    dbg $*
    # If we've previously decided we get faulty temperature readings from the IPMI sensors.. just get out
    bad_state_cpu='/cluster/var/state/no_cpu_temperatures_ipmi'
    [[ "$(strike ${bad_state_cpu} 'check')" == 'out' ]] && return 1

    # Try to use the IPMI sensors to gather the CPU and system temperatures - make sure the reported values are reasonable
    cpu_temps=''
    i=0
    # This really merits explanation: sensors is a CSV of various temperature sensors; field 4 is the value and
    # fields 9-11 are upper non-critical, upper critical, and upper non-recoverable temperatures respectively.
    # We record the temperature value, if valid, and in preference the upper non-recoverable temperature, the
    # upper critical temperature + 3, or the upper non-critical temperature + 5 (the offsets being to approximate
    # non-recoverable temperatures). We output these as an inequality: temp>max-offset, where offset is 0 for DF
    # nodes or 5 for air nodes
    for cpu_temp_line in $(awk -F ',' -v offset="${_offset}" -v max_default="${CPU_TEMP_MAX_DEFAULT}" '$2~"(CPU[0-9]+ Temp|CPU [0-9]+ Temp|CPU[0-9]+_TEMP|CPU Temp|CPU Temp [0-9]+)" && $4~"^[0-9.-]+$" {if($11~"^[0-9.]+$"){max=$11}else if($10~"^[0-9.]+$"){max=$10+3}else if($9~"^[0-9.]+$"){max=$9+5}else{max=max_default}{print int($4) ">" int(max) "-" offset}}' <<< "${sensors}"); do
        append=
        cpu_temp=$(cut -d '>' -f '1' <<< "${cpu_temp_line}")
        cpu_temp_max=$(( $(cut -d '>' -f '2' <<< "${cpu_temp_line}") ))
        if (( cpu_temp <= 5 || cpu_temp >= 150 )); then
            log "Found CPU temperature of ${cpu_temp}C, declaring IPMI sensors as faulty for CPU temperature readings"
            strike "${bad_state_cpu}"
            return 1
        else
            [[ -f "${bad_state_cpu}" ]] && rm -f "${bad_state_cpu}"
            # This is why we made that absurd awk above! The output itself is a test to evaluate whether we're safe or not
            if (( "${cpu_temp_line}" )); then
                if [[ "${NODETYPE}" == 'COMPUTE' ]] && shutoffNode "CPU${i} temperature is critical ${cpu_temp}C (max ${cpu_temp_max}C); shutting off node"; then
                    _crit=1
                    append="(CRITICAL MAX=${cpu_temp_max})"
                fi
	    # AMD is confident their EPYCs can go up to 100 degrees C consistently so no throttling for AMDs
            elif (( "${cpu_temp_line}-${TEMP_THROTTLE_MARGIN}" )); then
		    if ! grep -qE 'model name[[:space:]]:\ AMD\ EPYC\ (96[5,8]4|9734)' /proc/cpuinfo; then 
                    [[ "${NODETYPE}" == 'COMPUTE' ]] && _throttle=1
                    _warn=1
                    append="(HIGH MAX=${cpu_temp_max})"
		fi
            fi
            cpu_temps="${cpu_temps},${cpu_temp}${append}"
            _graphite="${GRAPHITE_HIERARCHY}.temperature.cpu${i} ${cpu_temp} $(date '+%s')\n${_graphite}"
            (( i++ ))
        fi
    done
    _graphite="${GRAPHITE_HIERARCHY}.freq.cpu ${cpu_freq} $(date '+%s')\n${_graphite}"
    { [[ -n "$cpu_temps" ]] && append _templog "cpu=${cpu_temps#,}"; } &&
    { append _templog "cpu_freq=${cpu_freq}"; } || return 1

    return 0

}

# A few things wrt our 600x Sapphire Rapids:
# - ipmi-sensors don't work here
# - ipmitool unable to query /dev/ipmi0 so will need to do this over lan
# hence a separate check for these
# TODO: consolidate the various cpu and temp checks into a single check
# so we call ipmi-sensors and ipmitool only once - these are heavy checks
# MurshidA: Need hours that I don't have for now so kicking this further down the road

checkCpuTempIPMISPR() {
    dbg $*
    # If we've previously decided we get faulty temperature readings from the IPMI sensors.. just get out
    bad_state_cpu='/cluster/var/state/no_cpu_temperatures_ipmi_spr'
    [[ "$(strike ${bad_state_cpu} 'check')" == 'out' ]] && return 1

    ipmiaddr="$(/bin/host ${HOSTNAME}-ipmi | awk '{ print $4 }')"
    [[ -z $ipmiaddr ]] && return 1

    cpu_temps=''
    i=0
    reading="$(timeout -s 9 20 ipmitool -H $ipmiaddr -U admin -P password sensor | awk -F'|' '/CPU[0-9]_TEMP/{print int($2)}')"
    while read cpu_temp; do
	[[ -z "$cpu_temps" ]] && cpu_temps="${cpu_temp}" || cpu_temps="${cpu_temps},${cpu_temp}"
	_graphite="${GRAPHITE_HIERARCHY}.temperature.cpu${i} ${cpu_temp} $(date '+%s')\n${_graphite}"
	(( i++ ))
    done <<< "$reading"
    _graphite="${GRAPHITE_HIERARCHY}.freq.cpu ${cpu_freq} $(date '+%s')\n${_graphite}"
    { [[ -n "$cpu_temps" ]] && append _templog "cpu=${cpu_temps#,}"; } &&
    { append _templog "cpu_freq=${cpu_freq}"; } || return 1

    return 0

}

checkCpuTempMarginIPMI() {
    dbg $*
    # #82467 check CPU temperature margin because some chassis like the Intel storage chassis do not work with coretemp
    bad_state_margin='/cluster/var/state/no_cpu_margin_temperatures_ipmi'
    [[ "$(strike ${bad_state_margin} 'check')" == 'out' ]] && return 1

    cpu_temp_margins=''
    i=1
    for cpu_temp_margin_line in $(awk -F ',' -v offset="${_offset}" -v max_default="${CPU_TEMP_MARGIN_MAX_DEFAULT}" '$2~"^P[0-9]+ Therm Margin$" && $4~"^[0-9.-]+$" {if($11~"^[0-9.-]+$"){max=$11}else if($10~"^[0-9.-]+$"){max=$10+3}else if($9~"^[0-9.-]+$"){max=$9+5}else{max=max_default}{print int($4) ">" int(max) "-" offset}}' <<< "${sensors}"); do
        append=
        cpu_temp_margin=$(cut -d '>' -f '1' <<< "${cpu_temp_margin_line}")
        cpu_temp_margin_max=$(( $(cut -d '>' -f '2' <<< "${cpu_temp_margin_line}") ))
        if (( cpu_temp_margin <= -100 || cpu_temp_margin >= 50 )); then
            log "Found CPU temperature margin of ${cpu_temp_margin}C, declaring IPMI sensors as faulty for CPU temperature margin readings"
            strike "${bad_state_margin}"
            return 1
        else
            [[ -f "${bad_state_margin}" ]] && rm -f "${bad_state_margin}"
            if (( "${cpu_temp_margin_line}" )); then
                if [[ "${NODETYPE}" == 'COMPUTE' ]] && shutoffNode "CPU$((i-1)) temperature margin is critical ${cpu_temp_margin}C (max ${cpu_temp_margin_max}C); shutting off node"; then
                    _crit=1
                    append="(CRITICAL MAX=${cpu_temp_margin_max})"
                fi
            elif (( "${cpu_temp_margin_line}-${TEMP_THROTTLE_MARGIN}" )); then
                [[ "${NODETYPE}" == 'COMPUTE' ]] && _throttle=1
                _warn=1
                append="(HIGH MAX=${cpu_temp_margin_max})"
            fi
            cpu_temp_margins="${cpu_temp_margins},${cpu_temp_margin}${append}"
            _graphite="${GRAPHITE_HIERARCHY}.temperature.cpu${i}_margin ${cpu_temp_margin} $(date '+%s')\n${_graphite}"
            (( i++ ))
        fi
    done
    [[ -n "${cpu_temp_margins}" ]] && append _templog "cpu_temp_margin=${cpu_temp_margins#,}" || return 1

    return 0

}

checkSysTempIPMI() {
    dbg $*
    # If we've previously decided we get faulty temperature readings from the IPMI sensors.. just get out
    bad_state_sys='/cluster/var/state/no_sys_temperatures_ipmi'
    [[ "$(strike ${bad_state_sys} 'check')" == 'out' ]] && return 1

    append=
    sys_temp_line=$(awk -F ',' -v offset="${_offset}" -v max_default="${SYS_TEMP_MAX_DEFAULT}" '$2~"^System Temp|^Sys Temp" && $4~"^[0-9.-]+$" {if($11~"^[0-9.]+$"){max=$11}else if($10~"^[0-9.]+$"){max=$10+3}else if($9~"^[0-9.]+$"){max=$9+5}else{max=max_default}{print int($4) ">" int(max) "-" offset}}' <<< "${sensors}" | head -n 1)
    if [[ -n "${sys_temp_line}" ]]; then

        sys_temp=$(cut -d '>' -f '1' <<< "${sys_temp_line}")
        sys_temp_max=$(( $(cut -d '>' -f '2' <<< "${sys_temp_line}") ))

        # #70047 read old system temperature up here so we can also see if we're changing temperatures too much
        old_sys_temp=
        [[ -f '/cluster/var/state/system' ]] && mtime_system="$(stat -c '%Y' '/cluster/var/state/system')" || mtime_system='0'
        [[ -f '/cluster/var/state/temperature' ]] && mtime_temp="$(stat -c '%Y' '/cluster/var/state/temperature')" || mtime_temp='0'
        if (( mtime_system != 0 || mtime_temp != 0 )); then
            (( mtime_system > mtime_temp )) && temp_file='/cluster/var/state/system' || temp_file='/cluster/var/state/temperature'
            old_sys_temp=$(grep -oE 'system=[0-9]+' "${temp_file}" | cut -d '=' -f '2')
        fi

        if (( sys_temp <= 5 || sys_temp >= 120 )); then
                log "Found system temperature of ${sys_temp}C, declaring IPMI sensors as faulty for system temperatures"
                strike "${bad_state_sys}"
                return 1
        elif [[ -n "${old_sys_temp}" ]] && (( sys_temp - old_sys_temp > 10 || old_sys_temp - sys_temp > 10 )); then
                # If we have "good" data from last run, let's keep that as the reported sys_temp until we get to a reasonable value again.
                # This strategy is not without flaws but otherwise a faulty sys_temp could get locked in. Do not report to grafana here.
                log "Found system temperature of ${sys_temp}C and old system temperature of ${old_sys_temp}C, declaring IPMI sensors as faulty for system temperatures"
                append _templog "system=${old_sys_temp}"
                strike "${bad_state_sys}"
                return 1
        else
            [[ -f "${bad_state_sys}" ]] && rm -f "${bad_state_sys}"
            if (( "${sys_temp_line}" )); then
                [[ "${NODETYPE}" == 'COMPUTE' ]] && shutoffNode "system temperature is critical ${sys_temp}C (max ${sys_temp_max}C); shutting off node"
                _crit=1
                append="(CRITICAL MAX=${sys_temp_max})"
            elif (( "${sys_temp_line}-${TEMP_THROTTLE_MARGIN}" )); then
                [[ "${NODETYPE}" == 'COMPUTE' ]] && _throttle=1
                _warn=1
                append="(HIGH MAX=${sys_temp_max})"
            fi
            [[ -n "${sys_temp}" ]] && append _templog "system=${sys_temp}${append}" || return 1
            _graphite="${GRAPHITE_HIERARCHY}.temperature.system ${sys_temp} $(date '+%s')\n${_graphite}"
        fi

    else
        return 1
    fi

    return 0

}

checkExitTempIPMI() {
    dbg $*
    # Looks at exit air temp
    bad_state_exit='/cluster/var/state/no_exit_temperatures_ipmi'
    [[ "$(strike ${bad_state_exit} 'check')" == 'out' ]] && return 1

    append=
    exit_temp_line=$(awk -F ',' -v offset="${_offset}" -v max_default="${SYS_TEMP_MAX_DEFAULT}" '$2=="Exit Air Temp" && $4~"^[0-9.-]+$" {if($11~"^[0-9.]+$"){max=$11}else if($10~"^[0-9.]+$"){max=$10+3}else if($9~"^[0-9.]+$"){max=$9+5}else{max=max_default}{print int($4) ">" int(max) "-" offset}}' <<< "${sensors}")
    if [[ -n "${exit_temp_line}" ]]; then
        exit_temp=$(cut -d '>' -f '1' <<< "${exit_temp_line}")
        exit_temp_max=$(( $(cut -d '>' -f '2' <<< "${exit_temp_line}") ))
        if (( exit_temp <= 5 || exit_temp >= 120 )); then
            log "Found exit air temperature of ${exit_temp}C, declaring IPMI sensors as faulty for exit air temperatures"
            strike "${bad_state_exit}"
            return 1
        else
            [[ -f "${bad_state_exit}" ]] && rm -f "${bad_state_exit}"
            if (( "${exit_temp_line}" )); then
                [[ "${NODETYPE}" == 'COMPUTE' ]] && shutoffNode "exit air is critical ${exit_temp}C (max ${exit_temp_max}C); shutting off node"
                _crit=1
                append="(CRITICAL MAX=${exit_temp_max})"
            elif (( "${exit_temp_line}-${TEMP_THROTTLE_MARGIN}" )); then
                [[ "${NODETYPE}" == 'COMPUTE' ]] && _throttle=1
                _warn=1
                append="(HIGH MAX=${exit_temp_max})"
            fi
            [[ -n "${exit_temp}" ]] && append _templog "exit=${exit_temp}${append}" || return 1
            _graphite="${GRAPHITE_HIERARCHY}.temperature.exit ${exit_temp} $(date '+%s')\n${_graphite}"
        fi
    else
        return 1
    fi

    return 0

}

checkPdbTempIPMI() {
    dbg $*
    bad_state_pdb='/cluster/var/state/no_pdb_temperatures_ipmi'
    [[ "$(strike ${bad_state_pdb} 'check')" == 'out' ]] && return 1

    pdb_temps=''
    i=0
    for pdb_temp_line in $(awk -F ',' -v offset="${_offset}" -v max_default="${PDB_TEMP_MAX_DEFAULT}" '$2~"^PDB_TEMP[0-9]+$" && $4~"^[0-9.-]+$" {if($11~"^[0-9.]+$"){max=$11}else if($10~"^[0-9.]+$"){max=$10+3}else if($9~"^[0-9.]+$"){max=$9+5}else{max=max_default}{print int($4) ">" int(max) "-" offset}}' <<< "${sensors}"); do
        append=
        pdb_temp=$(cut -d '>' -f '1' <<< "${pdb_temp_line}")
        pdb_temp_max=$(( $(cut -d '>' -f '2' <<< "${pdb_temp_line}") ))
        if (( pdb_temp <= 5 || pdb_temp >= 120 )); then
            log "Found PDB temperature of ${pdb_temp}C, declaring IPMI sensors as faulty for system readings for pdb temperatures"
            strike "${bad_state_pdb}"
            return 1
        else
            [[ -f "${bad_state_pdb}" ]] && rm -f "${bad_state_pdb}"
            if (( "${pdb_temp_line}" )); then
                [[ "${NODETYPE}" == 'COMPUTE' ]] && shutoffNode "PDB${i} temperature is critical ${pdb_temp}C (max ${pdb_temp_max}C); shutting off node"
                _crit=1
                append="(CRITICAL MAX=${pdb_temp_max})"
            elif (( "${pdb_temp_line}-${TEMP_THROTTLE_MARGIN}" )); then
                [[ "${NODETYPE}" == 'COMPUTE' ]] && _throttle=1
                _warn=1
                append="(HIGH MAX=${pdb_temp_max})"
            fi
            pdb_temps="${pdb_temps},${pdb_temp}${append}"
            _graphite="${GRAPHITE_HIERARCHY}.temperature.pdb${i} ${pdb_temp} $(date '+%s')\n${_graphite}"
            (( i++ ))
        fi
    done
    [[ -n "${pdb_temps}" ]] && append _templog "pdb=${pdb_temps#,}" || return 1

    return 0

}

checkInletTempIPMI() {
    dbg $*

    inlet_temp=$(echo "$sensors" | awk -F ',' '/Inlet\ Temp/ { print int($4)}')
    _graphite="${GRAPHITE_HIERARCHY}.temperature.inlet $inlet_temp $(date '+%s')\n${_graphite}"
    append _templog "inlet_temp=$inlet_temp"

}

checkPhiTemp() {
    dbg $*
    # Report temperatures for all Phi cards provided there are any on the machine
    ls /sys/class/mic/mic*/ > /dev/null 2>&1 || return 0
    PATH=/opt/intel/mic/bin/:$PATH
    [[ -x $(which micsmc) ]] || return 1

    philog=''
    total_power=0
    report_power=1
    result_micsmc="$(micsmc -t -f)"
    n_problematic=0
    needs_flashed=0
    for m in /sys/class/mic/mic*/; do
        mic="$(basename ${m})"
        [[ -f "/opt/intel/mic/filesystem/${mic}.image" ]] || needs_flashed=1
        temp=$(grep -A1 "${mic} (temp):" <<< "${result_micsmc}" | awk '/Cpu Temp/{print int($4)}')
        power=$(grep -A2 "${mic} (freq):" <<< "${result_micsmc}" | awk '/Total Power/{print int($4)}')
        # Try to dynamically get the critical shutoff temperature from IPMI, but otherwise just use the default.
        # I cannot see how to map micX (mic driver) to Xeon PhiY (IPMI) so just average available critical shutoffs.
        [[ -n "${sensors}" ]] && temp_max=$(awk -F ',' -v offset="${_offset}" -v max_default="${PHI_TEMP_MAX_DEFAULT}" '$2~"^Xeon Phi[0-9]+ Temp$" && $11~"^[0-9.]+$"{s+=$11;n++}END{if(n>0){print int(s/n)-offset}else{print int(max_default-offset)}}' <<< "${sensors}")
        # Try to add some sanity checks on critical temperature just in case...
        if [[ -z "${temp_max}" ]] || (( temp_max < 95 || temp_max > 120 )); then
            temp_max="$(( PHI_TEMP_MAX_DEFAULT - _offset ))"
        fi

        # 97089 further reduce the threshold for all Phis
        (( temp_max -= PHI_SHUTOFF_OFFSET ))

        if [[ -n "${power}" ]] && (( power > 0 )); then
            (( total_power += power ))
            _graphite="${GRAPHITE_HIERARCHY}.power.phi${mic#mic} ${power} $(date '+%s')\n${_graphite}"
        else
            # If any single Phi doesn't check in with power then we don't report the total at the end
            report_power=0
        fi
        graphite=1
        if [[ -z "${temp}" ]]; then
            _warn=1; graphite=0; (( n_problematic++ ))
            philog="${philog},${mic#mic}(UNREADABLE)"
        elif (( temp < 10 || temp > 150 )); then
            _warn=1; graphite=0; (( n_problematic++ ))
            philog="${philog},${mic#mic}(${temp}=FAULTY)"
        elif (( temp > temp_max )); then
            [[ "${NODETYPE}" == 'COMPUTE' ]] && shutoffNode "critical Phi temperature exceeded ${mic} is ${temp}C (critical ${temp_max}C)"
            _crit=1
            philog="${philog},${mic#mic}(${temp}=CRITICAL MAX=${temp_max})"
        elif (( temp > temp_max - TEMP_THROTTLE_MARGIN )); then
            [[ "${NODETYPE}" == 'COMPUTE' ]] && _throttle=1
            _warn=1
            philog="${philog},${mic#mic}(${temp}=HIGH MAX=${temp_max})"
        else
            philog="${philog},${mic#mic}(${temp})"
        fi
        (( n_problematic >= 2 )) && _crit=1
        (( graphite )) && _graphite="${GRAPHITE_HIERARCHY}.temperature.phi${mic#mic} ${temp} $(date '+%s')\n${_graphite}"
    done

    [[ -n "${philog}" ]] && append _templog "phi=${philog#,}"
    (( report_power )) && [[ -n "${total_power}" ]] && append _templog "phipwr=${total_power}W"
    [[ -z "${philog}" && -z "${total_power}" ]] && return 1

    return 0

}

checkGpuTemp() {
    dbg $*
    # Look at GPUs on machines with them present
    gpus_string=
    if grep -q 'nvidia' '/proc/modules' && [[ -x '/usr/bin/nvidia-smi' ]]; then
        output="$(/usr/bin/nvidia-smi -q -d temperature)"
        gpus=$(awk '/^GPU/{print $2}' <<< "${output}")
        if [[ -n "${gpus}" ]]; then
            gpu_id=0
            for gpu in ${gpus}; do
                throttled=
                shutdown=
                gpu_string=
                output_gpu=$(sed -rn "/^GPU ${gpu}/,/^GPU/p" <<< "${output}")
                if [[ -n "${output_gpu}" ]]; then
                    output_temp=$(grep -A3 'Temperature' <<< "${output_gpu}")
                    temp_current=$(awk '/GPU Current Temp/{if($5~"^[0-9]+$"){print int($5)}}' <<< "${output_temp}")
                    temp_shutdown=$(awk '/GPU Shutdown Temp/{if($5~"^[0-9]+$"){print int($5)}}' <<< "${output_temp}")
                    temp_slowdown=$(awk '/GPU Slowdown Temp/{if($5~"^[0-9]+$"){print int($5)}}' <<< "${output_temp}")
                    if [[ -n "${temp_current}" ]] && (( temp_current > 0 )); then
                        [[ -n "${temp_slowdown}" ]] && (( temp_current > temp_slowdown )) && throttled='(THROTTLED)' && _warn=1
                        [[ -n "${temp_shutdown}" ]] && (( temp_shutdown - temp_current < 10 )) && shutdown=",SHUTDOWN@${temp_shutdown}" && _crit=1
                        gpu_string="${temp_current}${throttled}${shutdown}"
                        _graphite="${GRAPHITE_HIERARCHY}.temperature.gpu${gpu_id} ${temp_current} $(date '+%s')\n${_graphite}"
                    fi
                fi
                [[ -n "${gpu_string}" ]] && gpus_string="${gpu_id}(${gpu_string}),${gpus_string}"
                (( gpu_id++ ))
            done
        fi
    fi
    # some temperature monitoring for amd gpus
    if grep -q 'amdgpu' '/proc/modules'; then
        gpu_num=$(ls -ld /sys/class/drm/card*/device/pp_table | wc -l)
        for (( gpu_id=0; gpu_id<gpu_num; gpu_id++ )); do
            gpu_string=
            # e.g. output is GPU Temperature: 40 C
            output_temp=$(cat "/sys/kernel/debug/dri/$gpu_id/amdgpu_pm_info" |grep 'GPU Temperature' |sed 's/[^0-9.]*//g')
            if (( output_temp > 0 )); then
                gpu_string=$output_temp
            fi
            [[ -n "${gpu_string}" ]] && gpus_string="${gpu_id}(${gpu_string}),${gpus_string}"
        done
    fi

    [[ -n "${gpus_string}" ]] && append _templog "gpu=${gpus_string%,}"

    return 0

}

checkDiskTemp() {
    dbg $*

    disk_temps=''
    disks="$(getInternalDisks)"
    for disk in ${disks}; do

        [[ -z "${disk}" ]] && continue

	[[ -f "${VARDIR}/.ignoredisk_${disk}" || $IGNOREDISKS =~ ${disk}(,|$) ]] && continue

        if [[ -s "/cluster/var/state/disk_serial_${disk}" ]]; then
            <"/cluster/var/state/disk_serial_${disk}" read -r disk_suffix
        else
            disk_suffix="$(stat -c '%Y' /dev/${disk})"
        fi

        bad_state_disk_base="/cluster/var/state/no_disk_temperatures_${disk}"
        bad_state_disk="${bad_state_disk_base}_${disk_suffix}"
        [[ -f "${bad_state_disk}" ]] && continue

        smart=$(timeout -k 1 10 smartctl -HA /dev/$disk)

        append=
        # #93653 check both 190 and 194 and report if either (or both) report a problem
        if grep -q '^190' <<< "${smart}"; then
            # 190 is Airflow_Temperature_Celsius
            disk_temp_190=$(awk '/^190/{if($10~"^[0-9]+"){print int($10)}}' <<< "${smart}")
            disk_message_190=$(awk '/^190/{print $9}' <<< "${smart}")
        fi
        if grep -q '^194' <<< "${smart}"; then
            # 194 is Temperature_Celsius
            disk_temp_194=$(awk '/^194/{if($10~"^[0-9]+"){print int($10)}}' <<< "${smart}")
            disk_message_194=$(awk '/^194/{print $9}' <<< "${smart}")
        fi

        if [[ -n "${disk_temp_190}" && -n "${disk_temp_194}" ]]; then
            if (( disk_temp_190 == disk_temp_194 )); then
                disk_temp="${disk_temp_194}"
            else
                # In this scenario we'll average and round so that we're able to report something sensible to graphite
                disk_temp="$(( (disk_temp_190 + disk_temp_194) / 2 ))"
            fi
            [[ "${disk_message_190}" == 'FAILING_NOW' || "${disk_message_194}" == 'FAILING_NOW' ]] && ! (<<<$HOSTNAME grep -qE '^[a-z]cop[0-9]{4}$') && append='=CRITICAL' && _crit=1
        elif [[ -n "${disk_temp_190}" ]]; then
            disk_temp="${disk_temp_190}"
            [[ "${disk_message_190}" == 'FAILING_NOW' ]] && ! (<<<$HOSTNAME grep -qE '^[a-z]cop[0-9]{4}$') && append='=CRITICAL' && _crit=1
        elif [[ -n "${disk_temp_194}" ]]; then
            disk_temp="${disk_temp_194}"
            [[ "${disk_message_194}" == 'FAILING_NOW' ]] && ! (<<<$HOSTNAME grep -qE '^[a-z]cop[0-9]{4}$') && append='=CRITICAL' && _crit=1
        else
            rm -f "${bad_state_disk_base}"*
            touch "${bad_state_disk}"
            continue
        fi
        disk_temps="${disk_temps},${disk}(${disk_temp}${append})"

        _graphite="${GRAPHITE_HIERARCHY}.temperature.disk_${disk} ${disk_temp} $(date '+%s')\n${_graphite}"

    done

    [[ -n "${disk_temps}" ]] && append _templog "disks=${disk_temps#,}"

    return 0

}

checkMegaBbuTemp() {
    dbg $*
    [[ -x '/opt/MegaRAID/MegaCli/MegaCli64' ]] || return 1
    bbu_temp="$(/opt/MegaRAID/MegaCli/MegaCli64 -AdpBbuCmd -GetBbuStatus -a0 -NoLog | awk '/^Temperature/{print int($2)}')"
    [[ "${bbu_temp}" =~ ^[0-9]+$ ]] || return 1
    _graphite="${GRAPHITE_HIERARCHY}.temperature.bbu ${bbu_temp} $(date '+%s')\n${_graphite}"
    append _templog "bbu=$bbu_temp"

    return 0

}

check3wareBbuTemp() {
    dbg $*
    controller="$(basename /sys/bus/pci/drivers/3w-9xxx/*/host*)"
    [[ "${controller}" =~ ^host[0-9]+$ ]] || return 1
    controller="c${controller#host}"
    bbu_temp=$(2>/dev/null tw_cli /${controller}/bbu show tempval | awk '/Battery Temperature/{print int($6)}')
    [[ "${bbu_temp}" =~ ^[0-9]+$ ]] || return 1
    _graphite="${GRAPHITE_HIERARCHY}.temperature.bbu ${bbu_temp} $(date '+%s')\n${_graphite}"
    append _templog "bbu=$bbu_temp"

    return 0

}

checkDiskTempMegaRaid() {
    dbg $*
    bad_state_disk_mega='/cluster/var/state/no_disk_temperatures_mega'
    [[ "$(strike ${bad_state_disk_mega} 'check')" == 'out' ]] && return 1

    [[ -x '/opt/MegaRAID/MegaCli/MegaCli64' ]] || strike "${bad_state_disk_mega}" 'out'

    local disk_temps=
    megaraid_output="$(/opt/MegaRAID/MegaCli/MegaCli64 -pdlist -a0 -NoLog)"

    # TODO can we write this more nicely with fewer pipes and whatnot?
    for slot in $(awk '/^Slot Number: [0-9]+$/{print $3}' <<< "${megaraid_output}"); do
        slot_output=$(sed -rn "/^Slot Number.+ ${slot}$/,/^Drive Temperature/p" <<< "${megaraid_output}")
        disk_temp=$(tail -n '1' <<< "${slot_output}" | sed -r 's/^Drive Temperature.+:([0-9]+)C.+/\1/')
        append disk_temps "${slot}(${disk_temp})" "," || continue
        _graphite="${GRAPHITE_HIERARCHY}.temperature.disk_${slot} ${disk_temp} $(date '+%s')\n${_graphite}"
    done

    [[ -n $disk_temps ]] && append _templog "disks=${disk_temps#,}C" || { strike "$bad_state_disk_mega"; return 1; }

    return 0

}

checkDiskTemp3ware() {
    dbg $*
    bad_state_disk_3ware='/cluster/var/state/no_disk_temperatures_3ware'

    [[ "$(strike ${bad_state_disk_3ware} 'check')" == 'out' ]] && return 1

    controller="$(basename /sys/bus/pci/drivers/3w-9xxx/*/host*)"
    [[ "${controller}" =~ ^host[0-9]+$ ]] || strike "${bad_state_disk_3ware}" 'out'
    controller="c${controller#host}"

    local disk_temps=
    for slot in $(tw_cli /${controller} show drivestatus | awk '/^p[0-9]+/{print $7}'); do
        smart=$(timeout -k 1 10 smartctl -HA -d "3ware,${slot}" '/dev/twa0')
        append=
        # #93653 check both 190 and 194 and report if either (or both) report a problem
        if grep -q '^190' <<< "${smart}"; then
            # 190 is Airflow_Temperature_Celsius
            disk_temp_190=$(awk '/^190/{if($10~"^[0-9]+"){print int($10)}}' <<< "${smart}")
            disk_message_190=$(awk '/^190/{print $9}' <<< "${smart}")
        fi
        if grep -q '^194' <<< "${smart}"; then
            # 194 is Temperature_Celsius
            disk_temp_194=$(awk '/^194/{if($10~"^[0-9]+"){print int($10)}}' <<< "${smart}")
            disk_message_194=$(awk '/^194/{print $9}' <<< "${smart}")
        fi

        if [[ -n "${disk_temp_190}" && -n "${disk_temp_194}" ]]; then
            if (( disk_temp_190 == disk_temp_194 )); then
                disk_temp="${disk_temp_194}"
            else
                # In this scenario we'll average and round so that we're able to report something sensible to graphite
                disk_temp="$(( (disk_temp_190 + disk_temp_194) / 2 ))"
            fi
            [[ "${disk_message_190}" == 'FAILING_NOW' || "${disk_message_194}" == 'FAILING_NOW' ]] && append='=CRITICAL' && _crit=1
        elif [[ -n "${disk_temp_190}" ]]; then
            disk_temp="${disk_temp_190}"
            [[ "${disk_message_190}" == 'FAILING_NOW' ]] && append='=CRITICAL' && _crit=1
        elif [[ -n "${disk_temp_194}" ]]; then
            disk_temp="${disk_temp_194}"
            [[ "${disk_message_194}" == 'FAILING_NOW' ]] && append='=CRITICAL' && _crit=1
        else
            continue
        fi

        disk_temps="${disk_temps},${slot}(${disk_temp}${append})"
        _graphite="${GRAPHITE_HIERARCHY}.temperature.disk_${slot} ${disk_temp} $(date '+%s')\n${_graphite}"
    done

    [[ -n "${disk_temps}" ]] && append _templog "disks=${disk_temps#,}C" || { strike "${bad_state_disk_3ware}"; return 1; }

    return 0

}


checkMemoryTemperature() {
    # Check the RAM temperature on KNLs via Thermal Sensor on Die (TSOD) registers.
    # The first 6 hex values (counting from LSB) correspond to the 3 memory channels,with each channel occupied by 2 DIMMS.
    # Channel_0 = DIMM 1,4
    # Channel_1 = DIMM 2,5
    # Channel_2 = DIMM 3,6
    #

    dbg $*
    declare -A TEMP_HEX
    declare -A TEMP_DEC
    CRITICAL_FLAG=0
    WARNING_FLAG=0
    CRITICAL_TEMP=95
    WARNING_TEMP=85
    PATH=$PATH:/sbin
    cpu=$(checkCpuType)
    dimm_serial_numbers=$(/cluster/bin/gogetid memory|tr -d '\n')
    # Only run this check on KNLs
    if [[ $cpu == knl ]]; then
        register_values=$(setpci -s fe:1e.0 0+60.L)
        if [[ ${#register_values} == 8 ]];then
            TEMP_HEX[chan0]=${register_values:6:2}
            TEMP_HEX[chan1]=${register_values:4:2}
            TEMP_HEX[chan2]=${register_values:2:2}
        else
            report_warn "Temperature" "Could not get Memory temperature reading from registers"
        fi

        #convert HEX values to DEC
        for i in ${!TEMP_HEX[@]}; do
            TEMP_DEC[$i]=$((16#${TEMP_HEX[$i]}))
            [[ ${TEMP_DEC[$i]} == 0 ]] && TEMP_DEC[$i]="Not_Installed"
        done

        #Check if values in array are greater than critical or warning, and alert if you find any values.
        for  i in ${!TEMP_DEC[@]}; do
            [[ ${TEMP_DEC[$i]}  -gt $CRITICAL_TEMP ]] && CRITICAL_FLAG=1
            [[ ${TEMP_DEC[$i]}  -ge $WARNING_TEMP && ${TEMP_DEC[$i]}  -le $CRITICAL_TEMP ]] && WARNING_FLAG=1
        done

        if [[ $CRITICAL_FLAG == 1 ]]; then
             report_warn "Temperature" " Memory Temperature(Degrees):  Channel_0 => ${TEMP_DEC[chan0]}  Channel_1 => ${TEMP_DEC[chan1]}  Channel_2 => ${TEMP_DEC[chan2]}"
             log "CRITICAL: Memory Temperature(Degrees);  Channel_0 => ${TEMP_DEC[chan0]}  Channel_1 => ${TEMP_DEC[chan1]}  Channel_2 => ${TEMP_DEC[chan2]}"
             log "DIMM serial numbers: $dimm_serial_numbers"
        elif [[ $WARNING_FLAG == 1 ]]; then
             report_warn "Temperature" " Memory Temperature(Degrees):  Channel_0 => ${TEMP_DEC[chan0]}  Channel_1 => ${TEMP_DEC[chan1]}  Channel_2 => ${TEMP_DEC[chan2]}"
             log "WARNING: Memory Temperature(Degrees); Channel_0 => ${TEMP_DEC[chan0]}  Channel_1 => ${TEMP_DEC[chan1]}  Channel_2 => ${TEMP_DEC[chan2]}"
             log "DIMM serial numbers: $dimm_serial_numbers"
        fi
    fi
}
