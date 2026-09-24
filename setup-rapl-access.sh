#!/usr/bin/env bash
set -Eeuo pipefail

script_name="${0##*/}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
rule_path="/etc/tmpfiles.d/mi-power-monitor-rapl.conf"
state_path="/var/lib/mi-power-monitor/rapl-permissions.before"
rapl_path="/sys/devices/virtual/powercap/intel-rapl"
action="install"

if [[ "${1:-}" == "--remove" ]]; then
    action="remove"
    shift
elif [[ "${1:-}" == "install" ]]; then
    shift
fi

target_user="${1:-${SUDO_USER:-}}"
if [[ -z "$target_user" ]]; then
    target_user="${USER:-}"
fi

if [[ "$target_user" == "root" || -z "$target_user" ]] || ! getent passwd "$target_user" >/dev/null; then
    printf 'Usage: %s [--remove] [desktop-user]\n' "$script_name" >&2
    printf 'Run this from the desktop account, or pass that account name when using sudo.\n' >&2
    exit 2
fi

if (( EUID != 0 )); then
    mode_arg="install"
    [[ "$action" == "remove" ]] && mode_arg="--remove"
    if command -v pkexec >/dev/null 2>&1; then
        exec pkexec "${script_dir}/${script_name}" "$mode_arg" "$target_user"
    elif command -v sudo >/dev/null 2>&1; then
        exec sudo -- "${script_dir}/${script_name}" "$mode_arg" "$target_user"
    else
        printf 'Administrator access is required. Run: sudo %s %s %s\n' "${script_dir}/${script_name}" "$action" "$target_user" >&2
        exit 1
    fi
fi

if [[ "$action" == "remove" ]]; then
    shopt -s nullglob
    energy_files=("${rapl_path}"/intel-rapl:*/energy_uj)
    if [[ -s "$state_path" ]]; then
        while read -r mode uid gid path; do
            [[ -e "$path" ]] || continue
            chown "${uid}:${gid}" "$path"
            chmod "$mode" "$path"
        done < "$state_path"
    else
        # Older versions did not save a permission snapshot; restore the
        # kernel's default root-only access for the counters this helper touched.
        for path in "${energy_files[@]}"; do
            chown root:root "$path"
            chmod 0400 "$path"
        done
    fi
    if [[ -e "$rule_path" ]]; then
        rm -- "$rule_path"
    fi
    if [[ -e "$state_path" ]]; then
        rm -- "$state_path"
    fi
    rmdir /var/lib/mi-power-monitor 2>/dev/null || true
    printf 'Removed the persistent RAPL permission rule and restored original access.\n'
    exit 0
fi

shopt -s nullglob
energy_files=("${rapl_path}"/intel-rapl:*/energy_uj)
if (( ${#energy_files[@]} == 0 )); then
    printf 'No Intel/AMD RAPL package energy counters were found under %s.\n' "$rapl_path" >&2
    exit 1
fi

if [[ ! -e "$state_path" ]]; then
    install -d -m 0755 /var/lib/mi-power-monitor
    tmp_state="$(mktemp)"
    trap 'rm -f -- "$tmp_state"' EXIT
    for energy_file in "${energy_files[@]}"; do
        if [[ -e "$rule_path" ]]; then
            # Migrate access rules created before permission snapshots existed.
            printf '400 0 0 %s\n' "$energy_file" >> "$tmp_state"
        else
            stat -c '%a %u %g %n' "$energy_file" >> "$tmp_state"
        fi
    done
    install -m 0600 "$tmp_state" "$state_path"
    trap - EXIT
    rm -- "$tmp_state"
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
