# Mi Power Monitor KDE

A KDE Plasma 6 power display widget for the Xiaomi smart plug 3 (`cuco.plug.v3`). This repository includes the complete backend source. Installation builds `xiaomi-power` from `backend/` and installs the Plasma widget; cloning the original backend repository is not required.

## Install

Requirements: KDE Plasma 6, `kpackagetool6`, and Go 1.25 or newer. First-time device setup also needs Python 3, pip, and git for the QR token setup helper. Python is not needed to read power after setup.

```bash
git clone https://github.com/galiandan/Mi_Power_Monitor_KDE.git
cd Mi_Power_Monitor_KDE
./install.sh
```

The installer builds the backend from the bundled Go source, installs it at `~/.local/bin/xiaomi-power`, installs the Plasma widget, and guides QR setup on first install. An existing `~/.config/xiaomi-power/config.json` is reused. After installation, add **Mi Power Monitor** from Plasma's widget list.

The widget runs `xiaomi-power --json` every two seconds and displays the reading and status. The backend also supports continuous polling on its own:

```bash
xiaomi-power --watch --json
```

## Uninstall

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

Go dependencies are pinned by `backend/go.mod` and `backend/go.sum`; QR setup dependencies are pinned by `backend/requirements.txt`. An internet connection is needed for the first build and QR setup.

## Build the backend separately

```bash
cd backend
CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o xiaomi-power ./cmd/xiaomi-power
```

For manual setup, copy `backend/config.example.json` to `~/.config/xiaomi-power/config.json`, fill in the device IP and token, and set the file permissions to `600` and directory permissions to `700`. Do not commit a real config file.

## License

GNU General Public License v3.0 only. See [LICENSE](LICENSE). The Go MIoT transport is a separate MIT-licensed dependency.
