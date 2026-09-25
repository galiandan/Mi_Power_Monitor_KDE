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
state_dir="/var/lib/mi-power-monitor"
state_path="${state_dir}/rapl-permissions.before"
owner_path="${state_dir}/rapl-permissions.owner"
action="install"

if [[ "${1:-}" == "--remove" ]]; then
    action="remove"
    shift
elif [[ "${1:-}" == "install" ]]; then
    shift
fi

target_user="${1:-${SUDO_USER:-${USER:-}}}"
if [[ "$target_user" == "root" || -z "$target_user" ]] || ! getent passwd "$target_user" >/dev/null; then
    say '用法：%s [--remove] [桌面用户名称]' 'Usage: %s [--remove] [desktop-user]' "$script_name" >&2
    say '请从桌面用户账户运行；使用 sudo 时，请传入该桌面账户名称。' 'Run this from the desktop account, or pass that account name when using sudo.' >&2
    exit 2
fi

IFS=: read -r _ _ target_uid target_gid _ _ _ < <(getent passwd "$target_user")
if [[ -z "$target_uid" || -z "$target_gid" ]]; then
    say '无法解析用户 %s 的 UID/GID。' 'Could not resolve UID/GID for %s.' "$target_user" >&2
    exit 1
fi

if (( EUID != 0 )); then
    mode_arg="install"
    [[ "$action" == "remove" ]] && mode_arg="--remove"
    if command -v pkexec >/dev/null 2>&1; then
        exec pkexec "${script_dir}/${script_name}" "$mode_arg" "$target_user"
    elif command -v sudo >/dev/null 2>&1; then
        exec sudo -- "${script_dir}/${script_name}" "$mode_arg" "$target_user"
    else
        say '需要管理员权限。请运行：sudo %s %s %s' 'Administrator access is required. Run: sudo %s %s %s' "${script_dir}/${script_name}" "$mode_arg" "$target_user" >&2
        exit 1
    fi
fi

if ! command -v flock >/dev/null 2>&1; then
    say '缺少 flock，无法安全串行化系统 RAPL 权限操作。' 'flock is required to serialize system RAPL permission changes.' >&2
    exit 1
fi
install -d -m 0755 /run/lock
permission_lock="/run/lock/mi-power-monitor-rapl.lock"
if [[ -L "$permission_lock" ]]; then
    say 'RAPL 权限锁路径不能是符号链接。' 'The RAPL permission lock path must not be a symbolic link.' >&2
    exit 1
fi
old_umask="$(umask)"
umask 077
exec 8>>"$permission_lock"
umask "$old_umask"
chmod 0600 "$permission_lock"
if ! flock -n 8; then
    say '另一个用户正在修改 RAPL 权限，请稍后重试。' 'Another RAPL permission operation is running; retry shortly.' >&2
    exit 1
fi

if [[ -s "$owner_path" ]]; then
    IFS=: read -r saved_uid saved_gid saved_user < "$owner_path"
    if [[ "$saved_uid" != "$target_uid" ]]; then
        say 'RAPL 权限规则已分配给用户 %s；请先由该用户卸载规则，再为其他用户配置。' 'RAPL access is assigned to %s; remove that rule as its owner before configuring another user.' "${saved_user:-UID ${saved_uid}}" >&2
        exit 1
    fi
fi

shopt -s nullglob
package_dirs=()
access_files=()
for rapl_dir in /sys/class/powercap/*rapl:*; do
    [[ -d "$rapl_dir" && "$(basename "$rapl_dir")" =~ rapl:[0-9]+$ ]] || continue
    domain_name="$(<"${rapl_dir}/name" 2>/dev/null || true)"
    package_name_re='^package([-_[:space:]]?[0-9]+)?$'
    [[ "${domain_name,,}" =~ $package_name_re ]] || continue
    package_dirs+=("$rapl_dir")
    for counter in energy_uj max_energy_range_uj; do
        [[ -e "${rapl_dir}/${counter}" ]] && access_files+=("${rapl_dir}/${counter}")
    done
done

if [[ "$action" == "remove" ]]; then
    if [[ -s "$state_path" ]]; then
        while read -r mode uid gid path; do
            [[ -e "$path" ]] || continue
            chown "${uid}:${gid}" "$path"
            chmod "$mode" "$path"
        done < "$state_path"
    elif [[ -f "$rule_path" ]]; then
        # Older versions saved no snapshot and granted every top-level RAPL
        # energy file to the user. Restore those rule paths to root-only access.
        while read -r type path _mode _user _group _age _argument; do
            [[ "$type" == z && "$path" == /sys/*/energy_uj ]] || continue
            domain="${path%/energy_uj}"
            [[ "${domain##*/}" =~ rapl:[0-9]+$ && -e "$path" ]] || continue
            chown root:root "$path"
            chmod 0400 "$path"
        done < "$rule_path"
    fi
    if [[ -e "$rule_path" ]]; then
        rm -- "$rule_path"
    fi
    if [[ -e "$state_path" ]]; then
        rm -- "$state_path"
    fi
    if [[ -e "$owner_path" ]]; then
        rm -- "$owner_path"
    fi
    rmdir "$state_dir" 2>/dev/null || true
    say '已移除持久化 RAPL 权限规则，并恢复原始访问权限。' 'Removed the persistent RAPL permission rule and restored original access.'
    exit 0
fi

if (( ${#package_dirs[@]} == 0 || ${#access_files[@]} == 0 )); then
    say '没有找到可配置的 CPU Package RAPL 计数器。' 'No configurable CPU Package RAPL counters were found.' >&2
    exit 1
fi

install -d -m 0755 "$state_dir" /etc/tmpfiles.d
if [[ ! -e "$state_path" ]]; then
    tmp_state="$(mktemp "${state_dir}/.permissions.XXXXXX")"
    trap 'rm -f -- "${tmp_state:-}"' EXIT
    for path in "${access_files[@]}"; do
        if [[ -e "$rule_path" ]]; then
            printf '400 0 0 %s\n' "$path" >> "$tmp_state"
        else
            stat -c '%a %u %g %n' "$path" >> "$tmp_state"
        fi
    done
    install -m 0600 "$tmp_state" "$state_path"
    rm -f -- "$tmp_state"
    trap - EXIT
fi

tmp_rule="$(mktemp /etc/tmpfiles.d/.mi-power-monitor-rapl.XXXXXX)"
trap 'rm -f -- "${tmp_rule:-}"' EXIT
for path in "${access_files[@]}"; do
    real_path="$(readlink -f -- "$path")"
    [[ "$real_path" == /sys/* ]] || continue
    printf 'z %s 0400 %s %s - -\n' "$real_path" "$target_uid" "$target_gid" >> "$tmp_rule"
done
if [[ ! -s "$tmp_rule" ]]; then
    say '无法解析 RAPL 计数器的实际 sysfs 路径。' 'Could not resolve Package RAPL counters to their sysfs paths.' >&2
    exit 1
fi
install -m 0644 "$tmp_rule" "$rule_path"
systemd-tmpfiles --create "$rule_path"
printf '%s:%s:%s\n' "$target_uid" "$target_gid" "$target_user" > "${owner_path}.tmp"
chmod 0600 "${owner_path}.tmp"
mv -f -- "${owner_path}.tmp" "$owner_path"
rm -f -- "$tmp_rule"
trap - EXIT

say '已允许用户 %s 读取所有 CPU Package RAPL 计数器。' 'Granted user %s access to all CPU Package RAPL counters.' "$target_user"
say '持久化规则：%s' 'Persistent rule: %s' "$rule_path"
for path in "${access_files[@]}"; do
    stat -c '%A %U:%G %n' "$path"
done
