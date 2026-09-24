# Mi Power Monitor KDE

KDE Plasma 6 桌面小组件，用于显示米家智能插座的实时功率。设备通信和账号配置由独立的 [`Mi_Power_Monitor`](https://github.com/galiandan/Mi_Power_Monitor) 后端负责；本仓库只负责显示。

## 依赖

- KDE Plasma 6
- 已安装并配置好的 `xiaomi-power` 命令（来自后端仓库）

小组件每两秒运行一次 `xiaomi-power --json`，读取后端输出的 JSON，并显示当前瓦数。请先按后端仓库说明完成设备登录或手动配置，并确认在终端中运行 `xiaomi-power --json` 能正常返回数据。

## 本地安装

```bash
kpackagetool6 --type Plasma/Applet --install .
```

安装后，在 Plasma 的小组件列表中添加 **Mi Power Monitor**。开发时更新文件后可运行：

```bash
kpackagetool6 --type Plasma/Applet --upgrade .
```

## 项目边界

- 后端仓库：读取插座功率、处理设备连接和配置。
- 本仓库：Plasma 6 小组件与功率读数显示。

## 许可证

GNU General Public License v3.0 only，详见 [LICENSE](LICENSE)。
