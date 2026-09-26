# Mi Power Monitor KDE

A KDE Plasma 6 power display widget for the Xiaomi smart plug 3 (`cuco.plug.v3`). This repository includes the complete backend source. Installation builds `xiaomi-power` from `backend/` and installs the Plasma widget; cloning the original backend repository is not required.

## Install

Requirements: KDE Plasma 6, `kpackagetool6`, Python 3, and Go 1.25 or newer. First-time QR setup also needs pip and git. If system policy restricts RAPL CPU counters, installation requests administrator authorization once and installs a fixed read-only CPU broker (requires sudo, visudo and /usr/bin/python3).

One-command install of the complete project, including backend, widget, and first-time device setup:

```bash
curl -fsSL https://raw.githubusercontent.com/galiandan/Mi_Power_Monitor_KDE/main/install-online.sh | bash
```

This downloads the repository and runs the unified installer. Cloning the repository and running `./install.sh` is also supported:

```bash
git clone https://github.com/galiandan/Mi_Power_Monitor_KDE.git
cd Mi_Power_Monitor_KDE
./install.sh
```

The installer builds the backend from the bundled Go source, installs it at `~/.local/bin/mi-power-monitor-backend`, and uses `kpackagetool6` to install the widget to `${XDG_DATA_HOME:-~/.local/share}/plasma/plasmoids/com.github.galiandan.mipowermonitor/`. First-time setup recommends Xiaomi QR sign-in and tries to open the local login page in the default browser; it also prints the URL in case you need to open it manually. Scan the QR code in the terminal with Mi Home on your phone and approve the sign-in. If the Xiaomi account has multiple plugs, QR setup lists them for selection by number without printing tokens. An existing `~/.config/xiaomi-power/config.json` is reused. After installation, add **Mi Power Monitor** from Plasma's widget list.

The panel shows rounded whole-watt readings for total, CPU, and GPU power. Total power comes from the Xiaomi Smart Plug 3; CPU power is calculated from Linux RAPL energy counters over a one-second sample; NVIDIA GPU power comes from `nvidia-smi`. Missing hardware, drivers, or RAPL read access show `--W`. Hover uses Plasma's native tooltip, left click cycles display modes, and the standard right-click menu opens settings.

If CPU shows `--W` because the RAPL `energy_uj` files are root-only, run `./setup-rapl-access.sh`. It installs a root-owned, argument-free reader at `/usr/local/libexec/mi-power-monitor/read-rapl` and a per-UID sudoers grant. It preserves sysfs permissions and installs no service. Python isolated mode prevents user module injection. Successful-command logging and PAM session/credential setup are disabled only for this reader to avoid polling log churn; denied commands remain logged. Legacy grants migrate only with complete snapshots and unchanged permissions. Each user can remove their own grant independently.

Full mode shows `83W · CPU 21W · GPU 37W`; Compact omits CPU/GPU labels; Total only keeps the whole-device reading. Disabling CPU/GPU also stops that collection; Total only stops both. Unsampled tooltip values show --W. GPU queries are skipped when an NVIDIA display device is not runtime-active; a hardware state change between checking and querying remains possible.

Once per polling cycle, the widget runs `mi-power-monitor-readings`: it samples CPU/GPU and total power concurrently, then emits all three values in one JSON snapshot. QML replaces the complete snapshot at once, preventing independently scheduled Plasma executable sources from updating the labels at different times. Total power comes from `mi-power-monitor-backend --json`; CPU/GPU readings come from this repository's `backend/read-sensors.sh`, outside the upstream plug backend API. The backend still supports continuous polling when used directly:

```bash
mi-power-monitor-backend --watch --json
```

## Uninstall

One-command uninstall, keeping device configuration and token:

```bash
curl -fsSL https://raw.githubusercontent.com/galiandan/Mi_Power_Monitor_KDE/main/uninstall-online.sh | bash
```

To also remove the Xiaomi config and token:

```bash
curl -fsSL https://raw.githubusercontent.com/galiandan/Mi_Power_Monitor_KDE/main/uninstall-online.sh | bash -s -- --purge-config
```

You can also run `./uninstall.sh` from a cloned repository.

```bash
./uninstall.sh
```

This keeps the device config and token. To remove them too:

```bash
./uninstall.sh --purge-config
```

## Repository layout

- `package/`: Standard Plasma 6 KPackage source package. `metadata.json` is at the package root; QML and configuration files are under `contents/`. Plasma installs it as `plasma/plasmoids/com.github.galiandan.mipowermonitor/`.
- `backend/`: Go reader, Python token setup helper, dependency manifests, and example config.
- `install.sh` / `uninstall.sh`: build, install, and remove the complete project.
- `CMakeLists.txt`: Plasma CMake install rule and a ZIP packaging target containing only the Plasmoid.
- `setup-rapl-access.sh`: authorize the fixed read-only CPU broker without changing sysfs permissions.
- `.github/workflows/sync-upstream-backend.yml`: checks the original backend daily and creates an auto-merge sync PR when source or dependency manifests change.
- `backend/read-sensors.sh`: reads RAPL CPU and NVIDIA GPU power.
- `backend/read-readings.py`: gathers one CPU, GPU, and total power snapshot for synchronized panel updates.

Go dependencies are pinned by `backend/go.mod` and `backend/go.sum`; QR setup dependencies are pinned by `backend/requirements.txt`. An internet connection is needed for the first build and QR setup.

## Develop and package the widget

Development dependencies are CMake, ECM, and Plasma development files. The CMake install rule targets the system Plasma plugin directory (and normally requires administrator privileges); use the user-level installer above for regular use. To create a ZIP containing only the standard Plasmoid package:

```bash
cmake -S . -B build
cmake --build build --target package-plasmoid
```

The archive is `build/com.github.galiandan.mipowermonitor.zip`. It contains only the standard Plasmoid frontend and can be used with the KDE Store or Plasma's install-from-local-file flow; the power-reading command still needs to be installed and configured with this repository's `install.sh`. Use `install.sh` for the complete integrated setup.

## Build the backend separately

```bash
cd backend
CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o xiaomi-power ./cmd/xiaomi-power
```

For manual setup, copy `backend/config.example.json` to `~/.config/xiaomi-power/config.json`, fill in the device IP and token, and set the file permissions to `600` and directory permissions to `700`. Do not commit a real config file.

## License

GNU General Public License v3.0 only. See [LICENSE](LICENSE). The Go MIoT transport is a separate MIT-licensed dependency.

### Standalone backend coexistence

The widget uses `mi-power-monitor-backend` and prefers its own bundled executable. The standalone installation retains `xiaomi-power`. Upgrades remove only legacy aliases owned by the widget. Both share the device config; uninstall with `--purge-config` preserves it while the other installation remains.
