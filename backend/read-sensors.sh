#!/usr/bin/env bash
set -u

cpu_power=""
for rapl_dir in /sys/class/powercap/*rapl:*; do
    [[ -d "$rapl_dir" ]] || continue
    [[ "$(basename "$rapl_dir")" =~ rapl:[0-9]+$ ]] || continue
    energy_file="${rapl_dir}/energy_uj"
    range_file="${rapl_dir}/max_energy_range_uj"
    [[ -r "$energy_file" && -r "$range_file" ]] || continue

    read -r before < "$energy_file" || continue
    read -r max_range < "$range_file" || continue
    [[ "$before" =~ ^[0-9]+$ && "$max_range" =~ ^[0-9]+$ && "$max_range" -gt 0 ]] || continue

    sleep 1
    read -r after < "$energy_file" || break
    [[ "$after" =~ ^[0-9]+$ ]] || break

    if (( after >= before )); then
        delta=$((after - before))
    else
        delta=$((max_range - before + after))
    fi
    cpu_power="$(awk -v delta="$delta" 'BEGIN { if (delta >= 0) printf "%.1f", delta / 1000000 }')"
    break
done

gpu_power=""
if command -v nvidia-smi >/dev/null 2>&1; then
    gpu_power="$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null \
        | awk '
            /^[[:space:]]*[0-9]+([.][0-9]+)?[[:space:]]*$/ { total += $1; count++ }
            END { if (count > 0) printf "%.1f", total }
        ' || true)"
fi

[[ "$cpu_power" =~ ^[0-9]+([.][0-9]+)?$ ]] || cpu_power=null
[[ "$gpu_power" =~ ^[0-9]+([.][0-9]+)?$ ]] || gpu_power=null
printf '{"cpu_power":%s,"gpu_power":%s}\n' "$cpu_power" "$gpu_power"
