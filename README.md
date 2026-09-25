# Mi Power Monitor KDE

米家智能插座 3（`cuco.plug.v3`）的 KDE Plasma 6 功率显示组件。仓库内包含完整后端源码；安装时从 `backend/` 构建 `xiaomi-power`，并安装 Plasma 小组件，不需要先安装或克隆原后端仓库。

## 安装

依赖：KDE Plasma 6、`kpackagetool6`、Python 3 和 Go 1.25 或更新版本。首次扫码配置还需要 pip 和 git。若 RAPL CPU 计数器被系统限制，安装时会请求一次管理员授权，将读取权仅交给当前用户。

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

安装脚本在独立版本目录构建后端，并原子切换 `current` 链接；成功升级后保留当前版和上一版。只复制列出的源码和清单，不会把开发目录里的虚拟环境或缓存带入安装。构建、配置或 Plasma 包升级失败时会尝试恢复旧链接和旧组件包；若旧版本清理失败会保留目录并提示。安装和卸载共用用户级互斥锁。已存在的配置会先离线校验 JSON、设备型号、IP、token 和超时；无效时引导重新扫码，旧配置在新配置成功保存前保留。首次安装优先使用米家二维码登录：脚本会尝试自动打开本机浏览器中的登录页面，并显示网址；若浏览器没有弹出，可手动访问该网址，再用手机米家 App 扫描终端中的二维码并确认登录。若账号下有多台插座，扫码后会列出候选设备供你按编号选择；不会输出 token。完成后，在 Plasma 小组件列表中添加 **Mi Power Monitor**。

面板显示整机、CPU 和 GPU 的整数瓦数，读取中或不可用时使用 `--W`。整机功耗来自米家智能插座 3；CPU 功耗只统计识别出的 RAPL Package 域，并使用单调时钟按真实采样时长计算；若采样窗口跨越系统休眠、计数器回退、Package 读取失败或样本不完整，该轮显示 `--W`。NVIDIA GPU 功耗由 `nvidia-smi` 提供，只有所有 GPU 都有有效读数时才汇总。没有对应硬件、驱动或 RAPL 读取权限时，相应项显示 `--W`。鼠标悬停显示 Plasma 原生提示，左键循环切换显示模式，右键可打开设置。

若 CPU 一项显示 `--W` 且系统的 RAPL Package 计数器仅允许 root 读取，可运行 `./setup-rapl-access.sh`。系统会要求管理员授权，并只将全部 Package 的能量及范围文件开放给当前用户；规则保存 UID/GID，并在重启后继续生效。每台系统当前只允许将规则分配给一个用户；需更换用户时，先以原用户运行卸载中的权限恢复，再重新配置。

默认 Full 模式显示 `⚡ 83W · CPU 21W · GPU 37W`；Compact 模式省去 CPU/GPU 标签；Total only 只显示整机功耗。可在组件设置里选择模式并隐藏 CPU 或 GPU。

组件按一秒间隔请求 `mi-power-monitor-readings`。采集器并行启动整机和 CPU/GPU 两路任务，两路子进程各有两秒硬截止；插座查询通过 Go 的 `--timeout 500ms` 将最多两次握手尝试和一次属性读取限制在约 1.5 秒内。CPU 使用约一秒的 RAPL 能量窗口，GPU 查询最多 1.4 秒。每项输出独立采样时间，整批 JSON 仍一次交给 QML 更新。非阻塞进程锁会让重叠轮询快速返回 `busy`，QML 忽略该结果，防止慢查询时重复启动采集树。整机读数来自 `xiaomi-power --json`；CPU/GPU 来自本仓库的 `backend/read-sensors.sh`，不属于上游插座后端接口。后端单独运行时仍支持长轮询：

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
- `.github/workflows/sync-upstream-backend.yml`：每天检查原后端仓库；发现代码或依赖清单更新时，先构建并运行脚本和 JSON 接口回归，再创建同步 PR 并请求自动合并。
- `backend/read-sensors.py` / `backend/read-sensors.sh`：按真实时间采样 RAPL Package 和 NVIDIA GPU；Shell 文件保留为启动兼容入口。
- `backend/read-readings.py`：汇总一次 CPU、GPU 和整机功耗采样，让面板同步刷新。

Go 通信依赖由 `backend/go.mod` 和 `backend/go.sum` 固定；扫码配置依赖由 `backend/requirements.txt` 固定。首次构建或首次扫码配置需要联网下载依赖。

## 开发与打包小组件

开发依赖：CMake、ECM 和 Plasma 开发文件。CMake 安装规则默认安装到系统 Plasma 插件目录（通常需要管理员权限）；日常安装建议使用上面的用户级安装器。生成仅包含标准 Plasmoid 包内容的 ZIP：

```bash
cmake -S . -B build
cmake --build build --target package-plasmoid
```

生成文件为 `build/com.github.galiandan.mipowermonitor.zip`，内容仅包含标准 Plasmoid 前端，可用于 KDE Store 或 Plasma 的“从本地文件安装”功能；功率读取命令仍需先通过本仓库的 `install.sh` 安装和配置。整合后端的一键安装仍使用 `install.sh`。

标准 Plasmoid 包不携带 Go 后端和传感器采集程序，这是 Plasma 包的安装边界。若运行命令未安装，面板原生 tooltip 会提示使用 KDE 仓库的 `install.sh`；已安装到 `~/.local/bin`、`/usr/local/bin`、`/usr/bin` 或当前 `PATH` 的采集命令均可被发现。

## 从源码单独构建后端

```bash
cd backend
CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o xiaomi-power ./cmd/xiaomi-power
```

手动配置时，将 `backend/config.example.json` 复制到 `~/.config/xiaomi-power/config.json`，填写设备 IP 和 token，并将配置文件权限设为 `600`。配置目录权限应为 `700`。不要提交真实配置文件。

## 许可证

GNU General Public License v3.0 only，详见 [LICENSE](LICENSE)。Go MIoT 通信库是单独的 MIT 许可证依赖。
