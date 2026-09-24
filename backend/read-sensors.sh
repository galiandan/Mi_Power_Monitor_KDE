#!/usr/bin/env bash
set -u

cpu_power=""
declare -a rapl_energy_files=()
declare -a rapl_range_files=()
declare -a rapl_before_values=()
for rapl_dir in /sys/class/powercap/*rapl:*; do
    [[ -d "$rapl_dir" ]] || continue
    [[ "$(basename "$rapl_dir")" =~ rapl:[0-9]+$ ]] || continue
    energy_file="${rapl_dir}/energy_uj"
    range_file="${rapl_dir}/max_energy_range_uj"
    [[ -r "$energy_file" && -r "$range_file" ]] || continue

    read -r before < "$energy_file" || continue
    read -r max_range < "$range_file" || continue
    [[ "$before" =~ ^[0-9]+$ && "$max_range" =~ ^[0-9]+$ && "$max_range" -gt 0 ]] || continue

    rapl_energy_files+=("$energy_file")
    rapl_range_files+=("$max_range")
    rapl_before_values+=("$before")
done

if (( ${#rapl_energy_files[@]} > 0 )); then
    sleep 1
    total_delta=0
    for index in "${!rapl_energy_files[@]}"; do
        read -r after < "${rapl_energy_files[$index]}" || continue
        [[ "$after" =~ ^[0-9]+$ ]] || continue
        before="${rapl_before_values[$index]}"
        max_range="${rapl_range_files[$index]}"
        if (( after >= before )); then
            delta=$((after - before))
        else
            delta=$((max_range - before + after))
        fi
        (( delta >= 0 )) && total_delta=$((total_delta + delta))
    done
    cpu_power="$(awk -v delta="$total_delta" 'BEGIN { if (delta >= 0) printf "%.1f", delta / 1000000 }')"
fi

gpu_power=""
if command -v nvidia-smi >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
        gpu_readings="$(timeout --signal=KILL 2s nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null || true)"
    else
        gpu_readings="$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null || true)"
    fi
    gpu_power="$(awk '
        /^[[:space:]]*[0-9]+([.][0-9]+)?[[:space:]]*$/ { total += $1; count++ }
        END { if (count > 0) printf "%.1f", total }
    ' <<< "$gpu_readings")"
fi

[[ "$cpu_power" =~ ^[0-9]+([.][0-9]+)?$ ]] || cpu_power=null
[[ "$gpu_power" =~ ^[0-9]+([.][0-9]+)?$ ]] || gpu_power=null
printf '{"cpu_power":%s,"gpu_power":%s}\n' "$cpu_power" "$gpu_power"
