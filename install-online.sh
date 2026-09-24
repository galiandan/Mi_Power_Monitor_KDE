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

repo_url="https://github.com/galiandan/Mi_Power_Monitor_KDE"
archive_url="${repo_url}/archive/refs/heads/main.tar.gz"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/mi-power-monitor-install.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT

for command in curl tar find; do
    if ! command -v "$command" >/dev/null 2>&1; then
        say '缺少必要命令：%s' 'Missing required command: %s' "$command" >&2
        exit 1
    fi
done

say '正在下载 KDE 功耗监控小组件及内置后端……' 'Downloading Mi Power Monitor KDE...'
curl --fail --location --silent --show-error "$archive_url" --output "${work_dir}/source.tar.gz"
tar -xzf "${work_dir}/source.tar.gz" -C "$work_dir"

source_dir="$(find "$work_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)"
if [[ -z "$source_dir" || ! -x "${source_dir}/install.sh" ]]; then
    say '下载的项目压缩包中没有找到 install.sh。' 'The downloaded archive does not contain install.sh.' >&2
    exit 1
fi

"${source_dir}/install.sh" "$@"
