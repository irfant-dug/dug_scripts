#!/usr/bin/env bash

echo "=== GPU Health Check ==="
echo "Host: $(hostname)"
echo "Date: $(date)"
echo

EXPECTED_GPU_COUNT=8
FAIL=0

# Expected PCI bus IDs
EXPECTED_BUSES=(
	"01:00.0"
	"11:00.0"
	"61:00.0"
	"71:00.0"
	"81:00.0"
	"91:00.0"
	"e1:00.0"
	"f1:00.0"
)

# Physical GPU locations (left → right)
declare -A GPU_LOCATION_HINT=(
	["f1:00.0"]="1st GPU from left"
	["e1:00.0"]="2nd GPU from left"
	["81:00.0"]="3rd GPU from left"
	["91:00.0"]="4th GPU from left"
	["71:00.0"]="5th GPU from left"
	["61:00.0"]="6th GPU from left"
	["01:00.0"]="7th GPU from left"
	["11:00.0"]="8th GPU from left (far right)"
)

# -------------------------------------------------
# GPU count from nvidia-smi
# -------------------------------------------------
GPU_COUNT_SMI=$(nvidia-smi -L 2>/dev/null | wc -l)

echo "Detected GPUs (nvidia-smi): $GPU_COUNT_SMI"
if [[ "$GPU_COUNT_SMI" -ne "$EXPECTED_GPU_COUNT" ]]; then
	echo "❌ ERROR: Expected $EXPECTED_GPU_COUNT GPUs"
	FAIL=1
fi
echo

# -------------------------------------------------
# PCI bus presence check (lspci)
# -------------------------------------------------
echo "Checking PCI Bus IDs:"

FOUND_BUSES=$(/usr/sbin/lspci | awk '{print $1}')
MISSING_BUSES=()

for BUS in "${EXPECTED_BUSES[@]}"; do
	if echo "$FOUND_BUSES" | grep -qi "^$BUS"; then
		echo "  ✅ $BUS present"
	else
		echo "  ❌ $BUS MISSING"
		MISSING_BUSES+=("$BUS")
		FAIL=1
	fi
done

# Physical location hint for missing GPUs (from lspci)
if [[ ${#MISSING_BUSES[@]} -gt 0 ]]; then
	echo
	for BUS in "${MISSING_BUSES[@]}"; do
		if [[ -n "${GPU_LOCATION_HINT[$BUS]}" ]]; then
			echo "$BUS is the ${GPU_LOCATION_HINT[$BUS]}"
		fi
	done
fi
echo

# -------------------------------------------------
# GPU count from lspci
# -------------------------------------------------
GPU_COUNT_LSPCI=$(/usr/sbin/lspci | grep -i nvidia | wc -l)

echo "Detected GPUs (lspci): $GPU_COUNT_LSPCI"

if [[ "$GPU_COUNT_LSPCI" -eq "$GPU_COUNT_SMI" ]]; then
	echo "✅ lspci and nvidia-smi agree"
else
	echo "❌ Mismatch between lspci and nvidia-smi"
	FAIL=1
fi
echo

# -------------------------------------------------
# Buses visible in lspci but missing from nvidia-smi
# -------------------------------------------------
echo "Cross-check: expected buses vs nvidia-smi visibility:"

SMI_BUSES_RAW=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null || true)
SMI_BUSES_NORMALIZED=$(echo "$SMI_BUSES_RAW" | sed 's/^00000000://; s/^0000://' | tr '[:upper:]' '[:lower:]')
MISSING_IN_SMI=()

for BUS in "${EXPECTED_BUSES[@]}"; do
	BUS_LOWER=${BUS,,}
	if echo "$SMI_BUSES_NORMALIZED" | grep -qi "^$BUS_LOWER$"; then
		echo "  ✅ $BUS visible in nvidia-smi"
	else
		echo "  ❌ $BUS NOT visible in nvidia-smi (but expected)"
		MISSING_IN_SMI+=("$BUS")
		FAIL=1
	fi
done

if [[ ${#MISSING_IN_SMI[@]} -gt 0 ]]; then
	echo
	echo "GPUs present on PCIe (lspci) but missing from nvidia-smi:"
	for BUS in "${MISSING_IN_SMI[@]}"; do
		LOC="${GPU_LOCATION_HINT[${BUS,,}]}"
		if [[ -n "$LOC" ]]; then
			echo "  $BUS ($LOC)"
		else
			echo "  $BUS"
		fi
	done
fi
echo

# -------------------------------------------------
# GPU inventory (with headers)
# -------------------------------------------------
echo "GPU Inventory:"
printf "  %-5s %-20s %-20s %-10s\n" "Index" "PCI Bus ID" "Model" "Temp(°C)"
printf "  %-5s %-20s %-20s %-10s\n" "-----" "-------------------" "-------------------" "--------"

nvidia-smi --query-gpu=index,pci.bus_id,name,temperature.gpu \
	--format=csv,noheader |
	while IFS=',' read -r IDX BUS NAME TEMP; do
		IDX=$(echo "$IDX" | xargs)
		BUS=$(echo "$BUS" | xargs)
		NAME=$(echo "$NAME" | xargs)
		TEMP=$(echo "$TEMP" | xargs)

		printf "  %-5s %-20s %-20s %-10s\n" "$IDX" "$BUS" "$NAME" "$TEMP"
	done

echo

# -------------------------------------------------
# PCIe link status (H200-safe) + width summary
# -------------------------------------------------
echo "PCIe Link Status:"

DEGRADED_LIST=""

while IFS=',' read -r IDX BUS GEN_CUR WIDTH_CUR GEN_MAX WIDTH_MAX; do
	[[ -z "$BUS" ]] && continue

	IDX=$(echo "$IDX" | xargs)
	BUS=$(echo "$BUS" | xargs)
	GEN_CUR=$(echo "$GEN_CUR" | xargs)
	WIDTH_CUR=$(echo "$WIDTH_CUR" | xargs)
	GEN_MAX=$(echo "$GEN_MAX" | xargs)
	WIDTH_MAX=$(echo "$WIDTH_MAX" | xargs)

	echo "  GPU $IDX: $BUS, current PCIe Gen$GEN_CUR x$WIDTH_CUR (max Gen$GEN_MAX x$WIDTH_MAX)"

	if ((WIDTH_CUR < 16)); then
		FAIL=1

		SHORT_BUS=$(echo "$BUS" | sed 's/^00000000://; s/^0000://')
		SHORT_BUS_LOWER=${SHORT_BUS,,}

		LOC=""
		if [[ -n "${GPU_LOCATION_HINT[$SHORT_BUS_LOWER]}" ]]; then
			LOC="${GPU_LOCATION_HINT[$SHORT_BUS_LOWER]}"
		fi

		MSG="  GPU $IDX has a width of $WIDTH_CUR when it's supposed to be 16 (BUS $BUS"
		if [[ -n "$LOC" ]]; then
			MSG+=", physical location: $LOC"
		fi
		MSG+=")"

		DEGRADED_LIST+=$'\n'"$MSG"
	fi
done < <(nvidia-smi \
	--query-gpu=index,pci.bus_id,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max \
	--format=csv,noheader 2>/dev/null)

if [[ -n "$DEGRADED_LIST" ]]; then
	echo
	echo "PCIe Width Issues:"
	echo "$DEGRADED_LIST"
fi

echo

#Logging---------------------------------------------------------
#different log location for KL and Houston
if [[ $(echo $HOSTNAME | grep -Eo "[kh]+nod") == "knod" ]]; then
	LOGGING_LOCATION="/data/kl7/dug/corporate/teamit/h200_health_check"

elif [[ $(echo $HOSTNAME | grep -Eo "[kh]+nod") == "hnod" ]]; then
	LOGGING_LOCATION="/h7/dug/IT/h200_hpl/logs/check_health"
fi
date +%Y%m%d_%H%M%S | tee -a $LOGGING_LOCATION/$HOSTNAME.txt
echo
nvidia-smi --query-gpu=serial,gpu_bus_id --format=csv,noheader | sed 's/00000000://' | sort -V | tee >(wc -l) | tee -a $LOGGING_LOCATION/$HOSTNAME.txt
echo | tee -a $LOGGING_LOCATION/$HOSTNAME.txt
#Logging---------------------------------------------------------

# -------------------------------------------------
# Final result
# -------------------------------------------------
if [[ "$FAIL" -eq 0 ]]; then
	echo "✅ GPU HEALTH CHECK PASSED"
	exit 0
else
	echo "❌ GPU HEALTH CHECK FAILED"
	exit 2
fi
