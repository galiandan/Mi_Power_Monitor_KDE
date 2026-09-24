#!/usr/bin/env bash
set -Eeuo pipefail

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
command_path="${HOME}/.local/bin/xiaomi-power"
sensor_command_path="${HOME}/.local/bin/mi-power-monitor-sensors"
readings_command_path="${HOME}/.local/bin/mi-power-monitor-readings"
config_dir="${config_home}/xiaomi-power"
config_path="${config_dir}/config.json"
plasmoid_id="com.github.galiandan.mipowermonitor"
plasmoid_config="${config_home}/plasma-org.kde.plasma.desktop-appletsrc"

if command -v qdbus6 >/dev/null 2>&1 && [[ -r "$plasmoid_config" ]]; then
    while IFS=: read -r containment_id applet_id; do
        [[ -n "$containment_id" && -n "$applet_id" ]] || continue
        qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript \
            "var w = panelById(${containment_id}).widgetById(${applet_id}); if (w) w.remove();" \
            >/dev/null 2>&1 || true
    done < <(awk -v plugin="$plasmoid_id" '
        /^\[Containments\]\[[0-9]+\]\[Applets\]\[[0-9]+\]$/ {
            line = $0
            sub(/^\[Containments\]\[/, "", line)
            split(line, parts, /\]\[/)
            containment = parts[1]
            applet = parts[3]
            sub(/\]$/, "", applet)
            in_applet = 1
            next
        }
        /^\[/ { in_applet = 0 }
        in_applet && $0 == "plugin=" plugin { print containment ":" applet }
    ' "$plasmoid_config")
fi

if command -v kpackagetool6 >/dev/null 2>&1; then
    kpackagetool6 --type Plasma/Applet --packageroot "$plasmoid_root" --remove "$plasmoid_id" 2>/dev/null || true
fi

if [[ -L "$command_path" ]]; then
    target="$(readlink -f -- "$command_path" 2>/dev/null || true)"
    case "$target" in
        "${app_dir}"/*)
            rm -- "$command_path"
            printf 'Removed command link: %s\n' "$command_path"
            ;;
        *) printf 'Kept command link not managed by this installer: %s\n' "$command_path" ;;
    esac
elif [[ -e "$command_path" ]]; then
    printf 'Kept non-symlink command file: %s\n' "$command_path"
fi

if [[ -L "$sensor_command_path" ]]; then
    target="$(readlink -f -- "$sensor_command_path" 2>/dev/null || true)"
    case "$target" in
        "${app_dir}"/*)
            rm -- "$sensor_command_path"
            printf 'Removed sensor command link: %s\n' "$sensor_command_path"
            ;;
        *) printf 'Kept command link not managed by this installer: %s\n' "$sensor_command_path" ;;
    esac
elif [[ -e "$sensor_command_path" ]]; then
    printf 'Kept non-symlink sensor command file: %s\n' "$sensor_command_path"
fi

if [[ -L "$readings_command_path" ]]; then
    target="$(readlink -f -- "$readings_command_path" 2>/dev/null || true)"
    case "$target" in
        "${app_dir}"/*)
            rm -- "$readings_command_path"
            printf 'Removed synchronized readings link: %s\n' "$readings_command_path"
            ;;
        *) printf 'Kept command link not managed by this installer: %s\n' "$readings_command_path" ;;
    esac
elif [[ -e "$readings_command_path" ]]; then
    printf 'Kept non-symlink readings command file: %s\n' "$readings_command_path"
fi

if [[ -d "$app_dir" ]]; then
    rm -rf -- "$app_dir"
    printf 'Removed bundled backend files: %s\n' "$app_dir"
fi

if [[ -f /etc/tmpfiles.d/mi-power-monitor-rapl.conf ]]; then
    "${script_dir}/setup-rapl-access.sh" --remove
fi

if [[ "$purge_config" == true ]]; then
    if [[ -e "$config_path" ]]; then
        rm -f -- "$config_path"
        printf 'Removed device config and token: %s\n' "$config_path"
    fi
    rmdir -- "$config_dir" 2>/dev/null || true
else
    printf 'Kept device config and token: %s\n' "$config_path"
    printf 'To remove it too, rerun with --purge-config.\n'
fi
