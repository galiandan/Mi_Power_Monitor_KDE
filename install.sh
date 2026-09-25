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
versions_dir="${app_dir}/versions"
current_link="${app_dir}/current"
config_path="${config_home}/xiaomi-power/config.json"
bin_dir="${HOME}/.local/bin"
command_path="${bin_dir}/xiaomi-power"
sensor_command_path="${bin_dir}/mi-power-monitor-sensors"
readings_command_path="${bin_dir}/mi-power-monitor-readings"
plasmoid_id="com.github.galiandan.mipowermonitor"
if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" && -w "$XDG_RUNTIME_DIR" && -O "$XDG_RUNTIME_DIR" ]]; then
    lock_dir="$XDG_RUNTIME_DIR"
else
    lock_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/mi-power-monitor"
    mkdir -p -m 0700 "$lock_dir"
    chmod 0700 "$lock_dir"
fi
lock_path="${lock_dir}/mi-power-monitor.install.lock"
candidate_dir=""
version_dir=""
previous_target=""
managed_paths=("$command_path" "$sensor_command_path" "$readings_command_path")
previous_links=("" "" "")
current_switched=false
command_links_changed=false
created_version=false
preserve_version=false

for command in go python3 kpackagetool6 flock install mv readlink; do
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

mkdir -p "$versions_dir" "$bin_dir" "$plasmoid_root"
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
    say '另一个安装或升级任务正在运行。' 'Another install or upgrade is already running.' >&2
    exit 1
fi

for index in "${!managed_paths[@]}"; do
    managed_path="${managed_paths[$index]}"
    if [[ -e "$managed_path" && ! -L "$managed_path" ]]; then
        say '目标位置已有非符号链接文件，无法覆盖：%s' 'Cannot replace existing non-symlink: %s' "$managed_path" >&2
        exit 1
    fi
    if [[ -L "$managed_path" ]]; then
        previous_links[$index]="$(readlink -- "$managed_path" 2>/dev/null || true)"
        existing_target="$(readlink -f -- "$managed_path" 2>/dev/null || true)"
        case "$existing_target" in
            "${app_dir}"/*) ;;
            *) say '目标链接不属于本组件，拒绝覆盖：%s' 'Refusing to replace an unmanaged command link: %s' "$managed_path" >&2; exit 1 ;;
        esac
    fi
done

if [[ -L "$current_link" ]]; then
    previous_target="$(readlink -f -- "$current_link" 2>/dev/null || true)"
    case "$previous_target" in
        "${versions_dir}"/*) ;;
        *) say '当前版本链接指向受管版本目录以外，停止升级：%s' 'The current version link is outside the managed versions directory: %s' "$current_link" >&2; exit 1 ;;
    esac
    if [[ ! -f "${previous_target}/.mi-power-monitor-managed" ]]; then
        say '当前版本没有本安装器的管理标记，拒绝自动升级：%s' 'The active version is not marked as managed; refusing automatic upgrade: %s' "$previous_target" >&2
        exit 1
    fi
elif [[ -e "$current_link" ]]; then
    say '当前版本路径不是符号链接，拒绝覆盖：%s' 'The current version path is not a symlink: %s' "$current_link" >&2
    exit 1
fi

cleanup() {
    local status=$?
    if [[ -n "$candidate_dir" && -d "$candidate_dir" ]]; then
        rm -rf -- "$candidate_dir"
    fi
    if (( status != 0 )) && [[ "$command_links_changed" == true ]]; then
        local index old_target rollback_link
        for index in "${!managed_paths[@]}"; do
            old_target="${previous_links[$index]:-}"
            if [[ -n "$old_target" ]]; then
                rollback_link="${managed_paths[$index]}.rollback.$$"
                if ln -s "$old_target" "$rollback_link"; then
                    mv -Tf "$rollback_link" "${managed_paths[$index]}" || rm -f -- "$rollback_link"
                fi
            else
                rm -f -- "${managed_paths[$index]}"
            fi
        done
    fi
    if (( status != 0 )) && [[ -n "$version_dir" && -d "$version_dir" && "$created_version" == true && "$preserve_version" == false ]]; then
        if [[ "$current_switched" == true && -n "$previous_target" && -d "$previous_target" ]]; then
            local restore_link="${app_dir}/.current-rollback.$$"
            if ln -s "${previous_target}" "$restore_link" && mv -Tf "$restore_link" "$current_link"; then
                say '安装失败，已恢复到上一版本：%s' 'Install failed; restored the previous version: %s' "$previous_target" >&2
            else
                rm -f -- "$restore_link"
                preserve_version=true
                say '自动恢复失败，请检查当前链接：%s' 'Automatic rollback failed; inspect the active link: %s' "$current_link" >&2
            fi
        elif [[ "$current_switched" == true ]]; then
            rm -f -- "$current_link"
        fi
        if [[ "$preserve_version" == false ]]; then
            rm -rf -- "$version_dir"
        fi
    fi
    rm -f -- "${command_path}.tmp.$$" "${sensor_command_path}.tmp.$$" \
        "${readings_command_path}.tmp.$$" "${current_link}.tmp.$$"
    exit "$status"
}
trap cleanup EXIT

candidate_dir="$(mktemp -d "${versions_dir}/.staging.XXXXXX")"
mkdir -p "${candidate_dir}/cmd/xiaomi-power" "${candidate_dir}/plasmoid"
for file in go.mod go.sum requirements.txt config.example.json xiaomi_power.py; do
    install -m 0644 "${script_dir}/backend/${file}" "${candidate_dir}/${file}"
done
install -m 0644 "${script_dir}/backend/cmd/xiaomi-power/main.go" "${candidate_dir}/cmd/xiaomi-power/main.go"
for file in read-readings.py read-sensors.py read-sensors.sh; do
    install -m 0755 "${script_dir}/backend/${file}" "${candidate_dir}/${file}"
done
install -m 0755 "${script_dir}/setup-rapl-access.sh" "${candidate_dir}/setup-rapl-access.sh"
cp -R "${script_dir}/package/." "${candidate_dir}/plasmoid/"
if kpackagetool6 --type Plasma/Applet --packageroot "$plasmoid_root" --list 2>/dev/null | grep -Fq "$plasmoid_id" \
    && [[ -d "${plasmoid_root}/${plasmoid_id}" ]]; then
    cp -R "${plasmoid_root}/${plasmoid_id}" "${candidate_dir}/previous-plasmoid"
fi

say '正在隔离目录中构建内置后端……' 'Building the bundled backend in an isolated version directory...'
(
    cd "$candidate_dir"
    CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags='-s -w' -o xiaomi-power ./cmd/xiaomi-power
    ./xiaomi-power -h >/dev/null
)

version_name="$(date -u +%Y%m%dT%H%M%SZ)-$$"
version_dir="${versions_dir}/${version_name}"
mv -- "$candidate_dir" "$version_dir"
candidate_dir=""
created_version=true
printf '%s\n' 'Mi Power Monitor KDE managed version' > "${version_dir}/.mi-power-monitor-managed"

prepare_python_setup() {
    for command in python3 git; do
        if ! command -v "$command" >/dev/null 2>&1; then
            say '首次二维码配置需要 %s。' 'Missing %s for first-time QR token setup.' "$command" >&2
            return 1
        fi
    done
    if [[ ! -x "${version_dir}/.venv/bin/python" ]]; then
        python3 -m venv "${version_dir}/.venv"
    fi
    "${version_dir}/.venv/bin/python" -m pip install --quiet --no-cache-dir -r "${version_dir}/requirements.txt"
    say '首次配置：推荐使用米家二维码扫码登录来绑定插座。' 'First-time setup: QR sign-in is recommended to connect your plug.'
    if [[ -t 0 ]]; then
        "${version_dir}/.venv/bin/python" "${version_dir}/xiaomi_power.py" --setup-cloud-qr
    elif [[ -r /dev/tty ]]; then
        "${version_dir}/.venv/bin/python" "${version_dir}/xiaomi_power.py" --setup-cloud-qr </dev/tty
    else
        say '二维码配置需要交互式终端，请在终端中运行 install.sh。' 'QR setup needs an interactive terminal. Run install.sh from a terminal.' >&2
        return 1
    fi
}

config_valid=false
if config_error="$(python3 "${version_dir}/xiaomi_power.py" --validate-config 2>&1 >/dev/null)"; then
    config_valid=true
else
    say '现有配置缺失或格式无效，将启动二维码配置。旧配置会在新配置成功保存前保留。' 'The existing config is missing or invalid. QR setup will run; the old config stays until a new one is saved.'
    [[ -z "$config_error" ]] || printf '  %s\n' "$config_error" >&2
    prepare_python_setup
    python3 "${version_dir}/xiaomi_power.py" --validate-config >/dev/null
    config_valid=true
fi

if [[ "$config_valid" == true && -t 0 ]]; then
    if supports_chinese; then
        read -r -p '检测到有效设备配置，要重新进行二维码登录吗？[y/N] ' answer
    else
        read -r -p 'A valid device config exists. Run QR login again? [y/N] ' answer
    fi
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        prepare_python_setup
        python3 "${version_dir}/xiaomi_power.py" --validate-config >/dev/null
    fi
else
    say '设备配置有效，继续使用现有配置。' 'The device config is valid; keeping the existing config.'
fi

shopt -s nullglob
package_dirs=()
for rapl_dir in /sys/class/powercap/*rapl:*; do
    [[ -d "$rapl_dir" && "${rapl_dir##*/}" =~ rapl:[0-9]+$ ]] || continue
    domain_name="$(<"${rapl_dir}/name" 2>/dev/null || true)"
    package_name_re='^package([-_[:space:]]?[0-9]+)?$'
    [[ "${domain_name,,}" =~ $package_name_re ]] && package_dirs+=("$rapl_dir")
done
if (( ${#package_dirs[@]} > 0 )); then
    rapl_readable=true
    counters_missing=false
    for domain in "${package_dirs[@]}"; do
        for counter in energy_uj max_energy_range_uj; do
            rapl_counter="${domain}/${counter}"
            if [[ ! -e "$rapl_counter" ]]; then
                counters_missing=true
                rapl_readable=false
            elif [[ ! -r "$rapl_counter" ]]; then
                rapl_readable=false
            fi
        done
    done
    if [[ "$rapl_readable" == false && "$counters_missing" == false ]]; then
        say 'RAPL CPU 能量计数器当前有 Package 不可读，正在申请仅当前用户可读的权限。' 'At least one CPU Package RAPL counter is unreadable; requesting user-only access.'
        if ! "${version_dir}/setup-rapl-access.sh" "$(id -un)"; then
            say 'CPU 功耗暂时不可用。之后可运行安装目录中的 setup-rapl-access.sh 再配置权限。' 'CPU power will remain unavailable. You can rerun setup-rapl-access.sh from the installed version later.' >&2
        fi
    elif [[ "$counters_missing" == true ]]; then
        say '检测到 CPU Package RAPL 接口缺少必要计数器，暂时无法启用 CPU 功耗读取。' 'A CPU Package RAPL interface is missing a required counter; CPU power cannot be enabled on this system.' >&2
    fi
fi

atomic_link() {
    local target="$1" link_path="$2" temp_link="${2}.tmp.$$"
    rm -f -- "$temp_link"
    ln -s -- "$target" "$temp_link"
    mv -Tf -- "$temp_link" "$link_path"
}

atomic_link "${app_dir}/current/xiaomi-power" "$command_path"
command_links_changed=true
atomic_link "${app_dir}/current/read-sensors.sh" "$sensor_command_path"
atomic_link "${app_dir}/current/read-readings.py" "$readings_command_path"
atomic_link "$version_dir" "$current_link"
current_switched=true

if kpackagetool6 --type Plasma/Applet --packageroot "$plasmoid_root" --list 2>/dev/null | grep -Fq "$plasmoid_id"; then
    if ! kpackagetool6 --type Plasma/Applet --packageroot "$plasmoid_root" --upgrade "${version_dir}/plasmoid"; then
        rollback_package="${version_dir}/previous-plasmoid"
        if [[ -n "$previous_target" && -d "${previous_target}/plasmoid" ]]; then
            rollback_package="${previous_target}/plasmoid"
        fi
        if [[ -d "$rollback_package" ]]; then
            if ! kpackagetool6 --type Plasma/Applet --packageroot "$plasmoid_root" --upgrade "$rollback_package"; then
                preserve_version=true
                say 'Plasma 包升级和回滚都失败，保留新后端以便恢复：%s' 'Plasma package upgrade and rollback both failed; keeping the new backend for recovery: %s' "$version_dir" >&2
            fi
        elif ! kpackagetool6 --type Plasma/Applet --packageroot "$plasmoid_root" --remove "$plasmoid_id"; then
            preserve_version=true
            say 'Plasma 包安装失败且无法移除残留，保留新后端以便恢复：%s' 'Plasma package installation failed and its partial package could not be removed; keeping the new backend: %s' "$version_dir" >&2
        fi
        exit 1
    fi
else
    if ! kpackagetool6 --type Plasma/Applet --packageroot "$plasmoid_root" --install "${version_dir}/plasmoid"; then
        if kpackagetool6 --type Plasma/Applet --packageroot "$plasmoid_root" --list 2>/dev/null | grep -Fq "$plasmoid_id"; then
            if ! kpackagetool6 --type Plasma/Applet --packageroot "$plasmoid_root" --remove "$plasmoid_id"; then
                preserve_version=true
                say 'Plasma 包安装失败且无法移除残留，保留新后端以便恢复：%s' 'Plasma package installation failed and its partial package could not be removed; keeping the new backend: %s' "$version_dir" >&2
            fi
        fi
        exit 1
    fi
fi

preserve_version=true

# Retain the active version and its immediate predecessor. Delete only marked
# version directories created by this installer; leave unknown entries alone.
keep_previous=""
if [[ -n "$previous_target" && -d "$previous_target" ]]; then
    keep_previous="$previous_target"
fi
for old_version in "${versions_dir}"/*; do
    [[ -d "$old_version" && ! -L "$old_version" ]] || continue
    [[ -f "${old_version}/.mi-power-monitor-managed" ]] || continue
    [[ "$old_version" == "$version_dir" || "$old_version" == "$keep_previous" ]] && continue
    if ! rm -rf -- "$old_version"; then
        say '旧版本清理失败，已保留目录：%s' 'Could not remove the old managed version; keeping: %s' "$old_version" >&2
    fi
done

say '\n已安装内置后端和 KDE Plasma 小组件。' '\nInstalled the bundled backend and KDE Plasma widget.'
say '后端命令：%s' 'Backend command: %s' "$command_path"
say '同步采样命令：%s' 'Synchronized readings command: %s' "$readings_command_path"
say '小组件目录：%s/%s' 'Plasma widget: %s/%s' "$plasmoid_root" "$plasmoid_id"
say '请从 Plasma 小组件列表中添加 Mi Power Monitor。' 'Add Mi Power Monitor from the Plasma widget list.'
if [[ ":${PATH}:" != *":${bin_dir}:"* ]]; then
    say '如果小组件找不到 xiaomi-power，请将此目录加入 PATH：%s' 'Add this directory to PATH if the widget cannot find xiaomi-power: %s' "$bin_dir"
fi
