#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
config_home="${XDG_CONFIG_HOME:-${HOME}/.config}"
plasmoid_root="${data_home}/plasma/plasmoids"
app_dir="${data_home}/mi-power-monitor"
backend_dir="${app_dir}/backend"
config_path="${config_home}/xiaomi-power/config.json"
bin_dir="${HOME}/.local/bin"
command_path="${bin_dir}/xiaomi-power"
sensor_command_path="${bin_dir}/mi-power-monitor-sensors"
plasmoid_id="com.github.galiandan.mipowermonitor"

for command in go kpackagetool6; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$command" >&2
        exit 1
    fi
done

if [[ "$(uname -s)" != Linux ]]; then
    printf 'This installer currently supports Linux only.\n' >&2
    exit 1
fi

go_version="$(go env GOVERSION | sed 's/^go//')"
if [[ "$go_version" =~ ^1\.([0-9]+) ]] && (( BASH_REMATCH[1] < 25 )); then
    printf 'Go 1.25 or newer is required (found %s).\n' "$(go version)" >&2
    exit 1
fi

mkdir -p "$backend_dir" "$bin_dir" "$plasmoid_root"
cp -R "${script_dir}/backend/." "$backend_dir/"
printf 'Building xiaomi-power from the bundled backend source...\n'
(
    cd "$backend_dir"
    CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags='-s -w' -o xiaomi-power ./cmd/xiaomi-power
)

if [[ ! -s "$config_path" ]]; then
    for command in python3 git; do
        if ! command -v "$command" >/dev/null 2>&1; then
            printf 'Missing %s for first-time QR token setup.\n' "$command" >&2
            exit 1
        fi
    done
    if [[ ! -x "${backend_dir}/.venv/bin/python" ]]; then
        python3 -m venv "${backend_dir}/.venv"
    fi
    "${backend_dir}/.venv/bin/python" -m pip install --quiet -r "${backend_dir}/requirements.txt"
    printf 'Starting one-time Xiaomi QR login to configure the plug.\n'
    if [[ -t 0 ]]; then
        "${backend_dir}/.venv/bin/python" "${backend_dir}/xiaomi_power.py" --setup-cloud-qr
    elif [[ -r /dev/tty ]]; then
        "${backend_dir}/.venv/bin/python" "${backend_dir}/xiaomi_power.py" --setup-cloud-qr </dev/tty
    else
        printf 'QR setup needs an interactive terminal. Run install.sh from a terminal.\n' >&2
        exit 1
    fi
else
    printf 'Using existing device config: %s\n' "$config_path"
fi

shopt -s nullglob
rapl_energy_files=(/sys/devices/virtual/powercap/intel-rapl/intel-rapl:*/energy_uj)
if (( ${#rapl_energy_files[@]} > 0 )); then
    rapl_readable=false
    for energy_file in "${rapl_energy_files[@]}"; do
        if [[ -r "$energy_file" ]]; then
            rapl_readable=true
            break
        fi
    done
    if [[ "$rapl_readable" == false ]]; then
        printf 'RAPL CPU energy counters are restricted; requesting user-only access.\n'
        if ! "${script_dir}/setup-rapl-access.sh" "$(id -un)"; then
            printf 'CPU power will remain unavailable. You can run setup-rapl-access.sh later.\n' >&2
        fi
    fi
fi

if [[ -e "$command_path" && ! -L "$command_path" ]]; then
    printf 'Cannot replace existing non-symlink: %s\n' "$command_path" >&2
    exit 1
fi
ln -sfn "${backend_dir}/xiaomi-power" "$command_path"

if [[ -e "$sensor_command_path" && ! -L "$sensor_command_path" ]]; then
    printf 'Cannot replace existing non-symlink: %s\n' "$sensor_command_path" >&2
    exit 1
fi
ln -sfn "${backend_dir}/read-sensors.sh" "$sensor_command_path"

if kpackagetool6 --type Plasma/Applet --packageroot "$plasmoid_root" --list 2>/dev/null | grep -Fq "$plasmoid_id"; then
    kpackagetool6 --type Plasma/Applet --packageroot "$plasmoid_root" --upgrade "${script_dir}/package"
else
    kpackagetool6 --type Plasma/Applet --packageroot "$plasmoid_root" --install "${script_dir}/package"
fi

printf '\nInstalled the bundled backend and KDE Plasma widget.\n'
printf 'Backend command: %s\n' "$command_path"
printf 'Plasma widget: %s/%s\n' "$plasmoid_root" "$plasmoid_id"
printf 'Add Mi Power Monitor from the Plasma widget list.\n'
if [[ ":${PATH}:" != *":${bin_dir}:"* ]]; then
    printf 'Add this directory to PATH if the widget cannot find xiaomi-power: %s\n' "$bin_dir"
fi
