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
readings_command_path="${bin_dir}/mi-power-monitor-readings"
plasmoid_id="com.github.galiandan.mipowermonitor"

for command in go python3 kpackagetool6; do
    if ! command -v "$command" >/dev/null 2>&1; then
        say '缺少必要命令：%s' 'Missing required command: %s' "$command" >&2
        exit 1
    fi
done

if [[ "$(uname -s)" != Linux ]]; then
    say '此安装程序目前仅支持 Linux。' 'This installer currently supports Linux only.' >&2
    exit 1
fi

go_version="$(go env GOVERSION | sed 's/^go//')"
if [[ "$go_version" =~ ^1\.([0-9]+) ]] && (( BASH_REMATCH[1] < 25 )); then
    say '需要 Go 1.25 或更新版本（当前为 %s）。' 'Go 1.25 or newer is required (found %s).' "$(go version)" >&2
    exit 1
fi

mkdir -p "$backend_dir" "$bin_dir" "$plasmoid_root"
cp -R "${script_dir}/backend/." "$backend_dir/"
say '正在从内置后端源码构建 xiaomi-power……' 'Building xiaomi-power from the bundled backend source...'
(
    cd "$backend_dir"
    CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags='-s -w' -o xiaomi-power ./cmd/xiaomi-power
)

if [[ ! -s "$config_path" ]]; then
    for command in python3 git; do
        if ! command -v "$command" >/dev/null 2>&1; then
            say '首次二维码配置需要 %s。' 'Missing %s for first-time QR token setup.' "$command" >&2
            exit 1
        fi
    done
    if [[ ! -x "${backend_dir}/.venv/bin/python" ]]; then
        python3 -m venv "${backend_dir}/.venv"
    fi
    "${backend_dir}/.venv/bin/python" -m pip install --quiet -r "${backend_dir}/requirements.txt"
    say '首次配置：推荐使用米家二维码扫码登录来绑定插座。' 'First-time setup: QR sign-in is recommended to connect your plug.'
    if [[ -t 0 ]]; then
        "${backend_dir}/.venv/bin/python" "${backend_dir}/xiaomi_power.py" --setup-cloud-qr
    elif [[ -r /dev/tty ]]; then
        "${backend_dir}/.venv/bin/python" "${backend_dir}/xiaomi_power.py" --setup-cloud-qr </dev/tty
    else
        say '二维码配置需要交互式终端，请在终端中运行 install.sh。' 'QR setup needs an interactive terminal. Run install.sh from a terminal.' >&2
        exit 1
    fi
else
    say '沿用已有设备配置：%s' 'Using existing device config: %s' "$config_path"
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
        say 'RAPL CPU 能量计数器当前受权限限制，正在申请仅当前用户可读的权限。' 'RAPL CPU energy counters are restricted; requesting user-only access.'
        if ! "${script_dir}/setup-rapl-access.sh" "$(id -un)"; then
            say 'CPU 功耗暂时不可用。之后可运行 setup-rapl-access.sh 再配置权限。' 'CPU power will remain unavailable. You can run setup-rapl-access.sh later.' >&2
        fi
    fi
fi

if [[ -e "$command_path" && ! -L "$command_path" ]]; then
    say '目标位置已有非符号链接文件，无法覆盖：%s' 'Cannot replace existing non-symlink: %s' "$command_path" >&2
    exit 1
fi
ln -sfn "${backend_dir}/xiaomi-power" "$command_path"

if [[ -e "$sensor_command_path" && ! -L "$sensor_command_path" ]]; then
    say '目标位置已有非符号链接文件，无法覆盖：%s' 'Cannot replace existing non-symlink: %s' "$sensor_command_path" >&2
    exit 1
fi
ln -sfn "${backend_dir}/read-sensors.sh" "$sensor_command_path"

if [[ -e "$readings_command_path" && ! -L "$readings_command_path" ]]; then
    say '目标位置已有非符号链接文件，无法覆盖：%s' 'Cannot replace existing non-symlink: %s' "$readings_command_path" >&2
    exit 1
fi
ln -sfn "${backend_dir}/read-readings.py" "$readings_command_path"

if kpackagetool6 --type Plasma/Applet --packageroot "$plasmoid_root" --list 2>/dev/null | grep -Fq "$plasmoid_id"; then
    kpackagetool6 --type Plasma/Applet --packageroot "$plasmoid_root" --upgrade "${script_dir}/package"
else
    kpackagetool6 --type Plasma/Applet --packageroot "$plasmoid_root" --install "${script_dir}/package"
fi

say '\n已安装内置后端和 KDE Plasma 小组件。' '\nInstalled the bundled backend and KDE Plasma widget.'
say '后端命令：%s' 'Backend command: %s' "$command_path"
say '同步采样命令：%s' 'Synchronized readings command: %s' "$readings_command_path"
say '小组件目录：%s/%s' 'Plasma widget: %s/%s' "$plasmoid_root" "$plasmoid_id"
say '请从 Plasma 小组件列表中添加 Mi Power Monitor。' 'Add Mi Power Monitor from the Plasma widget list.'
if [[ ":${PATH}:" != *":${bin_dir}:"* ]]; then
    say '如果小组件找不到 xiaomi-power，请将此目录加入 PATH：%s' 'Add this directory to PATH if the widget cannot find xiaomi-power: %s' "$bin_dir"
fi
