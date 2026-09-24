# Mi Power Monitor KDE

米家智能插座 3（`cuco.plug.v3`）的 KDE Plasma 6 功率显示组件。仓库内包含完整后端源码；安装时从 `backend/` 构建 `xiaomi-power`，并安装 Plasma 小组件，不需要先安装或克隆原后端仓库。

## 安装

依赖：KDE Plasma 6、`kpackagetool6`、Go 1.25 或更新版本。首次配置设备时还需要 Python 3、pip 和 git，用于运行扫码 token 配置程序。后端读取功率不需要 Python。

```bash
git clone https://github.com/galiandan/Mi_Power_Monitor_KDE.git
cd Mi_Power_Monitor_KDE
./install.sh
```

安装脚本会从仓库内的 Go 源码构建后端，将它放在 `~/.local/bin/xiaomi-power`，安装 Plasma 小组件，并在首次安装时引导扫码配置。若已有 `~/.config/xiaomi-power/config.json`，会直接复用。完成后，在 Plasma 小组件列表中添加 **Mi Power Monitor**。

小组件每两秒调用 `xiaomi-power --json`，以 JSON 读取功率并显示状态。后端单独运行时也支持长轮询：

```bash
xiaomi-power --watch --json
```

## 卸载

```bash
./uninstall.sh
```

默认保留设备配置和 token。如需一并删除：

```bash
./uninstall.sh --purge-config
```

## 仓库结构

- `package/`：Plasma 6 小组件，负责功率显示。
- `backend/`：独立后端的 Go 源码、Python token 配置工具、依赖清单和示例配置。
- `install.sh` / `uninstall.sh`：构建、安装及卸载整套项目。

Go 通信依赖由 `backend/go.mod` 和 `backend/go.sum` 固定；扫码配置依赖由 `backend/requirements.txt` 固定。首次构建或首次扫码配置需要联网下载依赖。

## 从源码单独构建后端

```bash
cd backend
CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o xiaomi-power ./cmd/xiaomi-power
```

手动配置时，将 `backend/config.example.json` 复制到 `~/.config/xiaomi-power/config.json`，填写设备 IP 和 token，并将配置文件权限设为 `600`。配置目录权限应为 `700`。不要提交真实配置文件。

## 许可证

GNU General Public License v3.0 only，详见 [LICENSE](LICENSE)。Go MIoT 通信库是单独的 MIT 许可证依赖。
