#!/usr/bin/env bash
set -Eeuo pipefail

repo_url="https://github.com/galiandan/Mi_Power_Monitor_KDE"
archive_url="${repo_url}/archive/refs/heads/main.tar.gz"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/mi-power-monitor-install.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT

for command in curl tar find; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$command" >&2
        exit 1
    fi
done

printf 'Downloading Mi Power Monitor KDE...\n'
curl --fail --location --silent --show-error "$archive_url" --output "${work_dir}/source.tar.gz"
tar -xzf "${work_dir}/source.tar.gz" -C "$work_dir"

source_dir="$(find "$work_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)"
if [[ -z "$source_dir" || ! -x "${source_dir}/install.sh" ]]; then
    printf 'The downloaded archive does not contain install.sh.\n' >&2
    exit 1
fi

"${source_dir}/install.sh" "$@"
