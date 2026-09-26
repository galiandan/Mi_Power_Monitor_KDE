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

# Only private paths are created or chmodded; shared system directories are untouched.
for command in flock python3 sudo visudo; do
    command -v "$command" >/dev/null || { echo "Missing dependency: $command" >&2; exit 1; }
done
[[ -x /usr/bin/python3 ]] || { echo "/usr/bin/python3 is required." >&2; exit 1; }
private_run=/run/mi-power-monitor
[[ ! -L "$private_run" ]] || exit 1
install -d -o root -g root -m 0700 "$private_run"
[[ ! -L "${private_run}/setup.lock" ]] || exit 1
exec 8>"${private_run}/setup.lock"
flock -n 8 || { echo 'Another RAPL setup is running.' >&2; exit 1; }

# Migrate old chmod-based grants only if the snapshot and applied state agree.
# Never guess original permissions or overwrite a subsequent admin change.
if [[ -e "$rule_path" || -e "$state_path" || -e "$owner_path" ]]; then
    python3 - "$rule_path" "$state_path" "$owner_path" "$target_uid" <<'MIGRATE'
import os, pathlib, stat, sys
rule, state, owner = map(pathlib.Path, sys.argv[1:4])
if not all(p.is_file() and not p.is_symlink() for p in (rule, state, owner)):
    sys.exit("旧 RAPL 记录不完整，请管理员检查；未猜测或修改原权限。 / Incomplete legacy RAPL state; admin review required.")
uid, gid, _ = owner.read_text().strip().split(":", 2)
if uid != sys.argv[4]:
    sys.exit("Legacy RAPL access belongs to another user; preserve their grant.")
changes = []
for line in state.read_text().splitlines():
    mode, old_uid, old_gid, raw = line.split(maxsplit=3)
    p = pathlib.Path(raw).resolve()
    if not str(p).startswith('/sys/devices/') or p.name not in ('energy_uj', 'max_energy_range_uj'):
        sys.exit('Invalid legacy RAPL snapshot path')
    if not p.exists():
        continue
    info = p.stat()
    original = (int(mode, 8), int(old_uid), int(old_gid))
    current = (stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid)
    if current == original:
        continue
    if current != (0o400, int(uid), int(gid)):
        sys.exit('RAPL 权限已改变，保留管理员设置。 / RAPL permissions changed; preserving administrator settings.')
    changes.append((p, original))
for p, (mode, uid, gid) in changes:
    os.chown(p, uid, gid)
    os.chmod(p, mode)
rule.unlink()
state.unlink()
owner.unlink()
MIGRATE
fi

helper_dir=/usr/local/libexec/mi-power-monitor
helper="${helper_dir}/read-rapl"
grant="/etc/sudoers.d/mi-power-monitor-rapl-${target_uid}"
marker='# Managed by Mi Power Monitor: read-only RAPL broker v1'
if [[ -e "$grant" || -L "$grant" ]]; then
    [[ ! -L "$grant" && "$(head -n 1 "$grant")" == "$marker" ]] || { echo 'Unmanaged sudoers path; refusing changes.' >&2; exit 1; }
fi
if [[ "$action" == remove ]]; then
    rm -f -- "$grant"
    shopt -s nullglob
    remaining=(/etc/sudoers.d/mi-power-monitor-rapl-*)
    if (( ${#remaining[@]} == 0 )) && [[ ! -L "$helper_dir" && -f "$helper" && ! -L "$helper" ]] && grep -Fqx "$marker" "$helper"; then
        rm -- "$helper"
        rmdir "$helper_dir" 2>/dev/null || true
    fi
    rmdir "$state_dir" 2>/dev/null || true
    say '已移除当前用户的 CPU 只读授权。' 'Removed this user’s read-only CPU grant.'
    exit 0
fi
[[ -d /etc/sudoers.d && ! -L "$helper_dir" ]] || exit 1
if [[ -e "$helper" || -L "$helper" ]]; then
    [[ ! -L "$helper" ]] && grep -Fqx "$marker" "$helper" || { echo 'Unmanaged helper; refusing overwrite.' >&2; exit 1; }
fi
# Parent path must be root-owned and not writable by other accounts.
python3 - "$helper_dir" <<'CHECK'
import pathlib, stat, sys
for p in [pathlib.Path(sys.argv[1]), *pathlib.Path(sys.argv[1]).parents]:
    if p.exists() and (p.is_symlink() or p.stat().st_uid != 0 or p.stat().st_mode & 0o022):
        sys.exit('Unsafe helper directory: ' + str(p))
CHECK
install -d -o root -g root -m 0755 "$helper_dir"
tmp_helper="$(mktemp "${helper_dir}/.reader.XXXXXX")"
tmp_grant="$(mktemp /etc/sudoers.d/.mi-power-monitor.XXXXXX)"
trap 'rm -f -- "$tmp_helper" "$tmp_grant"' EXIT
cat > "$tmp_helper" <<'READER'
#!/usr/bin/python3 -I
# Managed by Mi Power Monitor: read-only RAPL broker v1
import json
import pathlib
import re
import sys

if len(sys.argv) != 1:
    sys.exit(2)
values = {}
for domain in pathlib.Path('/sys/class/powercap').glob('*rapl:[0-9]*'):
    if not re.search(r'rapl:\d+$', domain.name):
        continue
    try:
        if not re.fullmatch(r'package(?:[-_ ]?\d+)?', (domain / 'name').read_text().strip(), re.I):
            continue
        for name in ('energy_uj', 'max_energy_range_uj'):
            path = (domain / name).resolve()
            if not str(path).startswith('/sys/devices/'):
                continue
            value = path.read_text(encoding='ascii').strip()
            if value.isdecimal():
                values[str(path)] = int(value)
    except (OSError, UnicodeError):
        continue
print(json.dumps(values))
READER
# Keep PAM credentials enabled: disabling both PAM options can leave sudo's
# PAM handle null and make libpam log errors on every sensor read.
printf '%s\n#%s ALL=(root) NOPASSWD: NOSETENV: %s ""\nDefaults!%s !log_allowed, !pam_session, pam_setcred\n' "$marker" "$target_uid" "$helper" "$helper" > "$tmp_grant"
visudo -cf "$tmp_grant"
chmod 0755 "$tmp_helper"
chmod 0440 "$tmp_grant"
chown root:root "$tmp_helper" "$tmp_grant"
mv -fT -- "$tmp_helper" "$helper"
mv -fT -- "$tmp_grant" "$grant"
trap - EXIT
say '已授权固定 CPU 只读命令；未修改 sysfs 权限或系统服务。' 'Granted the fixed read-only CPU command; sysfs permissions and system services are unchanged.'
