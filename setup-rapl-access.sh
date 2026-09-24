#!/usr/bin/env bash
set -Eeuo pipefail

supports_chinese() {
    local charmap
    charmap="$(locale charmap 2>/dev/null || true)"
    [[ "$charmap" == UTF-8 || "$charmap" == UTF8 ]]
}

say() {
    local chinese="$1" english="$2"
    shift 2
    if supports_chinese; then
        printf "$chinese\n" "$@"
    else
        printf "$english\n" "$@"
    fi
}

script_name="${0##*/}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
rule_path="/etc/tmpfiles.d/mi-power-monitor-rapl.conf"
state_path="/var/lib/mi-power-monitor/rapl-permissions.before"
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
	say '用法：%s [--remove] [桌面用户名称]' 'Usage: %s [--remove] [desktop-user]' "$script_name" >&2
	say '请从桌面用户账户运行；使用 sudo 时，请传入该桌面账户名称。' 'Run this from the desktop account, or pass that account name when using sudo.' >&2
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
		say '需要管理员权限。请运行：sudo %s %s %s' 'Administrator access is required. Run: sudo %s %s %s' "${script_dir}/${script_name}" "$action" "$target_user" >&2
        exit 1
    fi
fi

if [[ "$action" == "remove" ]]; then
    shopt -s nullglob
    energy_files=(/sys/class/powercap/*rapl:*/energy_uj)
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
    say '已移除持久化 RAPL 权限规则，并恢复原始访问权限。' 'Removed the persistent RAPL permission rule and restored original access.'
    exit 0
fi

shopt -s nullglob
energy_files=(/sys/class/powercap/*rapl:*/energy_uj)
if (( ${#energy_files[@]} == 0 )); then
    say '在 /sys/class/powercap 下没有找到 RAPL 能量计数器。' 'No RAPL energy counters were found under /sys/class/powercap.' >&2
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
for energy_file in "${energy_files[@]}"; do
    real_energy_file="$(readlink -f -- "$energy_file")"
    [[ "$real_energy_file" == /sys/* ]] || continue
    printf 'z %s 0400 %s %s - -\n' "$real_energy_file" "$target_user" "$target_user" >> "$tmp_rule"
done
if [[ ! -s "$tmp_rule" ]]; then
    say '无法解析 RAPL 计数器的实际 sysfs 路径。' 'Could not resolve the RAPL counters to their sysfs paths.' >&2
    exit 1
fi
install -m 0644 "$tmp_rule" "$rule_path"
systemd-tmpfiles --create "$rule_path"

say '已允许用户 %s 读取 RAPL 能量计数器。' 'Granted RAPL energy-counter read access to %s.' "$target_user"
say '持久化规则：%s' 'Persistent rule: %s' "$rule_path"
for energy_file in "${energy_files[@]}"; do
    stat -c '%A %U:%G %n' "$energy_file"
done
