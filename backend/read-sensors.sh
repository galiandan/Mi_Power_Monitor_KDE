#!/usr/bin/env bash
set -euo pipefail

script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
exec python3 "${script_path%/*}/read-sensors.py" "$@"
