# Mi Power Monitor KDE

A KDE Plasma 6 power display widget for the Xiaomi smart plug 3 (`cuco.plug.v3`). This repository includes the complete backend source. Installation builds `xiaomi-power` from `backend/` and installs the Plasma widget; cloning the original backend repository is not required.

## Install

Requirements: KDE Plasma 6, `kpackagetool6`, and Go 1.25 or newer. First-time device setup also needs Python 3, pip, and git for the QR token setup helper. If system policy restricts RAPL CPU counters, installation requests administrator authorization once and grants read access only to the current user.

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

The installer builds the backend from the bundled Go source, installs it at `~/.local/bin/xiaomi-power`, installs the Plasma widget, and guides QR setup on first install. An existing `~/.config/xiaomi-power/config.json` is reused. After installation, add **Mi Power Monitor** from Plasma's widget list.

The panel shows rounded whole-watt readings for total, CPU, and GPU power. Total power comes from the Xiaomi Smart Plug 3; CPU power is calculated from Linux RAPL energy counters over a one-second sample; NVIDIA GPU power comes from `nvidia-smi`. Missing hardware, drivers, or RAPL read access show `--W`. Hover uses Plasma's native tooltip, left click cycles display modes, and the standard right-click menu opens settings.

If CPU shows `--W` because the RAPL `energy_uj` files are root-only, run `./setup-rapl-access.sh`. It asks for administrator authorization and grants read access only to your desktop user. The rule persists across reboots.

Full mode shows `83W · CPU 21W · GPU 37W`; Compact omits CPU/GPU labels; Total only keeps the whole-device reading. Choose the mode and toggle CPU/GPU in the widget settings. The frontend requests readings asynchronously every second. The backend also supports continuous polling on its own:

The widget reads total power with `xiaomi-power --json`. The contract returns `model`, `power`, `unit`, and `available`; unavailable readings use `power: null` and may include `error`. Plasma's executable data engine delivers stdout when a command exits, so the widget polls the one-shot command once per second. Use `--watch` for direct backend use or clients that consume a continuous stream. CPU/GPU readings come from this repository's `backend/read-sensors.sh`, outside the upstream plug backend API.

```bash
xiaomi-power --watch --json
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

- `package/`: Plasma 6 widget and power display.
- `backend/`: Go reader, Python token setup helper, dependency manifests, and example config.
- `install.sh` / `uninstall.sh`: build, install, and remove the complete project.
- `setup-rapl-access.sh`: configure persistent, user-only access to RAPL energy counters.
- `.github/workflows/sync-upstream-backend.yml`: checks the original backend daily and creates an auto-merge sync PR when source or dependency manifests change.
- `backend/read-sensors.sh`: reads RAPL CPU and NVIDIA GPU power.

Go dependencies are pinned by `backend/go.mod` and `backend/go.sum`; QR setup dependencies are pinned by `backend/requirements.txt`. An internet connection is needed for the first build and QR setup.

## Build the backend separately

```bash
cd backend
CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o xiaomi-power ./cmd/xiaomi-power
```

For manual setup, copy `backend/config.example.json` to `~/.config/xiaomi-power/config.json`, fill in the device IP and token, and set the file permissions to `600` and directory permissions to `700`. Do not commit a real config file.

## License

GNU General Public License v3.0 only. See [LICENSE](LICENSE). The Go MIoT transport is a separate MIT-licensed dependency.
