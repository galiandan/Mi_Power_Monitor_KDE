#!/usr/bin/env bash
set -Eeuo pipefail

script_name="${0##*/}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
rule_path="/etc/tmpfiles.d/mi-power-monitor-rapl.conf"
rapl_path="/sys/devices/virtual/powercap/intel-rapl"

target_user="${1:-${SUDO_USER:-}}"
if [[ -z "$target_user" ]]; then
    target_user="${USER:-}"
fi

if [[ "$target_user" == "root" || -z "$target_user" ]] || ! getent passwd "$target_user" >/dev/null; then
    printf 'Usage: %s [desktop-user]\n' "$script_name" >&2
    printf 'Run this from the desktop account, or pass that account name when using sudo.\n' >&2
    exit 2
fi

if (( EUID != 0 )); then
    if command -v pkexec >/dev/null 2>&1; then
        exec pkexec "${script_dir}/${script_name}" "$target_user"
    elif command -v sudo >/dev/null 2>&1; then
        exec sudo -- "${script_dir}/${script_name}" "$target_user"
    else
        printf 'Administrator access is required. Run: sudo %s %s\n' "${script_dir}/${script_name}" "$target_user" >&2
        exit 1
    fi
fi

shopt -s nullglob
energy_files=("${rapl_path}"/intel-rapl:*/energy_uj)
if (( ${#energy_files[@]} == 0 )); then
    printf 'No Intel/AMD RAPL package energy counters were found under %s.\n' "$rapl_path" >&2
    exit 1
fi

install -d -m 0755 /etc/tmpfiles.d
tmp_rule="$(mktemp)"
trap 'rm -f -- "$tmp_rule"' EXIT
printf 'z %s/intel-rapl:*/energy_uj 0400 %s %s - -\n' "$rapl_path" "$target_user" "$target_user" > "$tmp_rule"
install -m 0644 "$tmp_rule" "$rule_path"
systemd-tmpfiles --create "$rule_path"

printf 'Granted RAPL energy-counter read access to %s.\n' "$target_user"
printf 'Persistent rule: %s\n' "$rule_path"
for energy_file in "${energy_files[@]}"; do
    stat -c '%A %U:%G %n' "$energy_file"
done
