# Mi Power Monitor KDE

米家智能插座 3（`cuco.plug.v3`）的 KDE Plasma 6 功率显示组件。仓库内包含完整后端源码；安装时从 `backend/` 构建 `xiaomi-power`，并安装 Plasma 小组件，不需要先安装或克隆原后端仓库。

## 安装

依赖：KDE Plasma 6、`kpackagetool6`、Go 1.25 或更新版本。首次配置设备时还需要 Python 3、pip 和 git，用于运行扫码 token 配置程序。若 RAPL CPU 计数器被系统限制，安装时会请求一次管理员授权，将读取权仅交给当前用户。

一键下载安装整套项目（后端、小组件和首次设备配置）：

```bash
curl -fsSL https://raw.githubusercontent.com/galiandan/Mi_Power_Monitor_KDE/main/install-online.sh | bash
```

这条命令下载仓库并运行统一安装脚本，不需要先单独安装后端或 Plasma 小组件。也可以 clone 仓库后运行 `./install.sh`：

```bash
git clone https://github.com/galiandan/Mi_Power_Monitor_KDE.git
cd Mi_Power_Monitor_KDE
./install.sh
```

安装脚本会从仓库内的 Go 源码构建后端，将它放在 `~/.local/bin/xiaomi-power`，并通过 `kpackagetool6` 安装 Plasma 小组件到 `${XDG_DATA_HOME:-~/.local/share}/plasma/plasmoids/com.github.galiandan.mipowermonitor/`。首次安装时会引导扫码配置。若米家账号下有多台插座，扫码后会列出候选设备供你按编号选择；不会输出 token。若已有 `~/.config/xiaomi-power/config.json`，会直接复用。完成后，在 Plasma 小组件列表中添加 **Mi Power Monitor**。

面板显示整机、CPU 和 GPU 的整数瓦数，读取中或不可用时使用 `--W`。整机功耗来自米家智能插座 3；CPU 功耗读取 Linux RAPL 能量计数器并按 1 秒采样间隔计算；NVIDIA GPU 功耗由 `nvidia-smi` 提供。没有对应硬件、驱动或 RAPL 读取权限时，相应项显示 `--W`。鼠标悬停显示 Plasma 原生提示，左键循环切换显示模式，右键可打开设置。

若 CPU 一项显示 `--W` 且系统的 RAPL `energy_uj` 文件仅允许 root 读取，可运行 `./setup-rapl-access.sh`。系统会要求管理员授权，并只将 RAPL 能量文件开放给当前用户；权限规则会在重启后继续生效。

默认 Full 模式显示 `⚡ 83W · CPU 21W · GPU 37W`；Compact 模式省去 CPU/GPU 标签；Total only 只显示整机功耗。可在组件设置里选择模式并隐藏 CPU 或 GPU。前端每秒异步读取数据，后端单独运行时也支持长轮询：

组件通过 `xiaomi-power --json` 读取整机功耗。接口返回 `model`、`power`、`unit`、`available`，不可用时 `power` 为 `null`，并可附带 `error`。Plasma 的 executable 数据引擎在命令结束后才交付 stdout，所以组件按一秒间隔调用单次读取；`--watch` 则留给直接运行后端或其他能消费持续输出的客户端。CPU/GPU 使用本仓库的 `backend/read-sensors.sh`，不属于上游插座后端接口。

```bash
xiaomi-power --watch --json
```

## 卸载

一键卸载（保留设备配置和 token）：

```bash
curl -fsSL https://raw.githubusercontent.com/galiandan/Mi_Power_Monitor_KDE/main/uninstall-online.sh | bash
```

如果还要删除米家配置和 token：

```bash
curl -fsSL https://raw.githubusercontent.com/galiandan/Mi_Power_Monitor_KDE/main/uninstall-online.sh | bash -s -- --purge-config
```

也可以在 clone 下来的仓库中运行 `./uninstall.sh`。

```bash
./uninstall.sh
```

默认保留设备配置和 token。如需一并删除：

```bash
./uninstall.sh --purge-config
```

## 仓库结构

- `package/`：标准 Plasma 6 KPackage 源码包。`metadata.json` 位于包根目录，QML 和配置文件位于 `contents/`；KDE Plasma 会将它安装为 `plasma/plasmoids/com.github.galiandan.mipowermonitor/`。
- `backend/`：独立后端的 Go 源码、Python token 配置工具、依赖清单和示例配置。
- `install.sh` / `uninstall.sh`：构建、安装及卸载整套项目。
- `CMakeLists.txt`：Plasma CMake 安装规则，并提供仅包含 Plasmoid 文件的 ZIP 打包目标。
- `setup-rapl-access.sh`：为当前用户设置持久、仅用户可读的 RAPL 权限。
- `.github/workflows/sync-upstream-backend.yml`：每天检查原后端仓库；发现代码或依赖清单更新时创建同步 PR 并启用自动合并。
- `backend/read-sensors.sh`：以低开销读取 RAPL CPU 和 NVIDIA GPU 功耗。

Go 通信依赖由 `backend/go.mod` 和 `backend/go.sum` 固定；扫码配置依赖由 `backend/requirements.txt` 固定。首次构建或首次扫码配置需要联网下载依赖。

## 开发与打包小组件

开发依赖：CMake、ECM 和 Plasma 开发文件。CMake 安装规则默认安装到系统 Plasma 插件目录（通常需要管理员权限）；日常安装建议使用上面的用户级安装器。生成仅包含标准 Plasmoid 包内容的 ZIP：

```bash
cmake -S . -B build
cmake --build build --target package-plasmoid
```

生成文件为 `build/com.github.galiandan.mipowermonitor.zip`，内容仅包含标准 Plasmoid 前端，可用于 KDE Store 或 Plasma 的“从本地文件安装”功能；功率读取命令仍需先通过本仓库的 `install.sh` 安装和配置。整合后端的一键安装仍使用 `install.sh`。

## 从源码单独构建后端

```bash
cd backend
CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o xiaomi-power ./cmd/xiaomi-power
```

手动配置时，将 `backend/config.example.json` 复制到 `~/.config/xiaomi-power/config.json`，填写设备 IP 和 token，并将配置文件权限设为 `600`。配置目录权限应为 `700`。不要提交真实配置文件。

## 许可证

GNU General Public License v3.0 only，详见 [LICENSE](LICENSE)。Go MIoT 通信库是单独的 MIT 许可证依赖。
