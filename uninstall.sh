#!/usr/bin/env bash
set -uo pipefail

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

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
purge_config=false
case "${1:-}" in
    "") ;;
    --purge-config) purge_config=true ;;
    --help|-h)
        printf 'Usage: uninstall.sh [--purge-config]\n'
        printf 'Removes the widget and bundled backend; keeps the device token by default.\n'
        exit 0
        ;;
    *) printf 'Unknown option: %s\nUsage: uninstall.sh [--purge-config]\n' "$1" >&2; exit 2 ;;
esac

data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
config_home="${XDG_CONFIG_HOME:-${HOME}/.config}"
plasmoid_root="${data_home}/plasma/plasmoids"
app_dir="${data_home}/mi-power-monitor"
versions_dir="${app_dir}/versions"
command_path="${HOME}/.local/bin/xiaomi-power"
sensor_command_path="${HOME}/.local/bin/mi-power-monitor-sensors"
readings_command_path="${HOME}/.local/bin/mi-power-monitor-readings"
config_dir="${config_home}/xiaomi-power"
config_path="${config_dir}/config.json"
plasmoid_id="com.github.galiandan.mipowermonitor"
failed=0
permission_restore_failed=false
package_remove_failed=false
if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" && -w "$XDG_RUNTIME_DIR" && -O "$XDG_RUNTIME_DIR" ]]; then
    lock_dir="$XDG_RUNTIME_DIR"
else
    lock_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/mi-power-monitor"
    mkdir -p -m 0700 "$lock_dir"
    chmod 0700 "$lock_dir"
fi
lock_path="${lock_dir}/mi-power-monitor.install.lock"

if command -v flock >/dev/null 2>&1; then
    if [[ -L "$lock_path" ]]; then
        say '安装锁路径不能是符号链接：%s' 'The install lock path must not be a symbolic link: %s' "$lock_path" >&2
        exit 1
    fi
    old_umask="$(umask)"
    umask 077
    exec 9>>"$lock_path"
    umask "$old_umask"
    chmod 0600 "$lock_path"
    if ! flock -n 9; then
        say '安装或升级任务正在运行，稍后再试卸载。' 'An install or upgrade is running; retry uninstall after it finishes.' >&2
        exit 1
    fi
fi

# Remove instances from the running Plasma state, including unsaved Desktop
# instances as well as panel instances. The plugin ID is constant and not
# derived from any config-file contents.
if command -v qdbus6 >/dev/null 2>&1; then
    plasma_script="var all=panels().concat(desktops()); var removed=0; for (var i=0;i<all.length;i++){var c=all[i]; var ids=c.widgetIds; for (var j=ids.length-1;j>=0;j--){var w=c.widgetById(ids[j]); if(w && w.type==='${plasmoid_id}'){w.remove(); removed++;}}} print('removed='+removed);"
    if plasma_result="$(qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$plasma_script" 2>/dev/null)"; then
        say '已从正在运行的 Plasma 桌面和面板移除组件实例。' 'Removed live widget instances from Plasma panels and desktops.'
    else
        say '无法连接正在运行的 Plasma；将继续卸载文件，配置中的桌面实例会在下次启动时变为失效项。' 'Could not contact Plasma; continuing file cleanup. Saved Desktop references may remain inactive until the next session.' >&2
    fi
elif [[ -r "${config_home}/plasma-org.kde.plasma.desktop-appletsrc" ]]; then
    say '未找到 qdbus6，无法清理正在运行的桌面实例。' 'qdbus6 was not found; live widget instances could not be removed.' >&2
fi

if command -v kpackagetool6 >/dev/null 2>&1; then
    if kpackagetool6 --type Plasma/Applet --packageroot "$plasmoid_root" --list 2>/dev/null | grep -Fq "$plasmoid_id"; then
        if ! kpackagetool6 --type Plasma/Applet --packageroot "$plasmoid_root" --remove "$plasmoid_id"; then
            say 'Plasma 拒绝移除组件包：%s' 'Plasma failed to remove the widget package: %s' "$plasmoid_id" >&2
            failed=1
            package_remove_failed=true
        fi
    fi
else
    installed_package="${plasmoid_root}/${plasmoid_id}"
    if [[ -d "$installed_package" ]]; then
        if ! rm -rf -- "$installed_package"; then
            say '未找到 kpackagetool6，且无法删除组件目录：%s' 'kpackagetool6 is unavailable and the widget directory could not be removed: %s' "$installed_package" >&2
            failed=1
            package_remove_failed=true
        fi
    fi
fi

remove_managed_link() {
    local link_path="$1" label="$2" raw_target resolved
    if [[ "$package_remove_failed" == true && -L "$link_path" ]]; then
        say '保留命令链接，因为 Plasma 组件包仍在：%s' 'Keeping the command link while the Plasma package remains installed: %s' "$link_path"
        return
    fi
    if [[ "$permission_restore_failed" == true && -L "$link_path" ]]; then
        say '保留命令链接，便于恢复 RAPL 权限：%s' 'Keeping the command link so RAPL permissions can still be restored: %s' "$link_path"
        return
    fi
    if [[ -L "$link_path" ]]; then
        raw_target="$(readlink -- "$link_path" 2>/dev/null || true)"
        resolved="$(readlink -f -- "$link_path" 2>/dev/null || true)"
        if [[ "$raw_target" == "${app_dir}/current/"* || "$resolved" == "${app_dir}/"* ]]; then
            if rm -- "$link_path"; then
                say '已移除命令链接：%s' 'Removed managed command link: %s' "$link_path"
            else
                say '无法移除命令链接：%s' 'Could not remove command link: %s' "$link_path" >&2
                failed=1
            fi
        else
            say '保留非本组件管理的链接：%s' 'Keeping unmanaged command link: %s' "$link_path"
        fi
    elif [[ -e "$link_path" ]]; then
        say '保留同名普通文件：%s' 'Keeping an existing non-symlink file: %s' "$link_path"
    fi
}

rapl_rule="/etc/tmpfiles.d/mi-power-monitor-rapl.conf"
rapl_state="/var/lib/mi-power-monitor/rapl-permissions.before"
rapl_owner="/var/lib/mi-power-monitor/rapl-permissions.owner"
if [[ -e "$rapl_rule" || -e "$rapl_state" || -e "$rapl_owner" ]]; then
    rapl_helper="${app_dir}/current/setup-rapl-access.sh"
    if [[ ! -x "$rapl_helper" ]]; then
        rapl_helper="${script_dir}/setup-rapl-access.sh"
    fi
    if [[ -x "$rapl_helper" ]]; then
        if ! "$rapl_helper" --remove; then
            say 'RAPL 权限恢复失败；保留后端目录供恢复使用。之后可重试：%s --remove' 'RAPL permission restoration failed; keeping the backend directory for recovery. Retry with: %s --remove' "$rapl_helper" >&2
            permission_restore_failed=true
            failed=1
        fi
    else
        say 'RAPL 权限状态仍存在，但找不到恢复脚本（规则：%s；权限记录：%s）。' 'RAPL permission state remains, but its recovery helper is missing (rule: %s; snapshot: %s).' "$rapl_rule" "$rapl_state" >&2
        permission_restore_failed=true
        failed=1
    fi
fi

remove_managed_link "$command_path" 'backend'
remove_managed_link "$sensor_command_path" 'sensor'
remove_managed_link "$readings_command_path" 'readings'

if [[ "$permission_restore_failed" == false && "$package_remove_failed" == false && -d "$versions_dir" ]]; then
    if [[ -L "${app_dir}/current" ]]; then
        raw_current="$(readlink -- "${app_dir}/current" 2>/dev/null || true)"
        if [[ "$raw_current" == "${versions_dir}/"* ]]; then
            rm -f -- "${app_dir}/current" || failed=1
        fi
    fi
    for managed_version in "${versions_dir}"/*; do
        [[ -d "$managed_version" && ! -L "$managed_version" ]] || continue
        [[ -f "${managed_version}/.mi-power-monitor-managed" ]] || continue
        if ! rm -rf -- "$managed_version"; then
            say '无法清理受管版本目录：%s' 'Could not remove managed version directory: %s' "$managed_version" >&2
            failed=1
        fi
    done
    rmdir "$versions_dir" 2>/dev/null || true
    # Do not remove old or unknown files in the application root.
elif [[ "$permission_restore_failed" == false && "$package_remove_failed" == false && -d "${app_dir}/backend" ]]; then
    # Remove the known pre-versioned layout only after RAPL restoration. Keep
    # the directory if any unknown data remains.
    rm -f -- "${app_dir}/backend/xiaomi-power" "${app_dir}/backend/read-readings.py" \
        "${app_dir}/backend/read-sensors.sh" "${app_dir}/backend/read-sensors.py" \
        "${app_dir}/backend/xiaomi_power.py" "${app_dir}/backend/go.mod" \
        "${app_dir}/backend/go.sum" "${app_dir}/backend/requirements.txt" \
        "${app_dir}/backend/config.example.json" 2>/dev/null || true
    rm -rf -- "${app_dir}/backend/cmd/xiaomi-power" 2>/dev/null || true
    rmdir "${app_dir}/backend/cmd" "${app_dir}/backend" "$app_dir" 2>/dev/null || true
fi

if [[ "$purge_config" == true ]]; then
    if [[ -e "$config_path" || -L "$config_path" ]]; then
        if rm -f -- "$config_path"; then
            say '已删除设备配置和 token：%s' 'Removed device config and token: %s' "$config_path"
        else
            say '无法删除设备配置：%s' 'Could not remove device config: %s' "$config_path" >&2
            failed=1
        fi
    fi
    rmdir "$config_dir" 2>/dev/null || true
else
    say '保留设备配置和 token：%s' 'Kept device config and token: %s' "$config_path"
    say '如需同时删除，请使用 --purge-config。' 'Rerun with --purge-config to remove it too.'
fi

if [[ "$permission_restore_failed" == false && "$package_remove_failed" == false ]]; then
    rmdir "$app_dir" 2>/dev/null || true
fi

if (( failed != 0 )); then
    say '卸载有步骤未完成；请根据上方信息重试或手动处理残留。' 'Some uninstall steps did not finish; retry or handle the listed leftovers.' >&2
    exit 1
fi
say '卸载完成。' 'Uninstall complete.'
