import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    readonly property int displayMode: Math.max(0, Math.min(2, Number(plasmoid.configuration.displayMode || 0)))
    readonly property bool showCpu: Boolean(plasmoid.configuration.showCpu)
    readonly property bool showGpu: Boolean(plasmoid.configuration.showGpu)
    readonly property bool anyReadingAvailable: totalAvailable || cpuAvailable || gpuAvailable
    property bool keepSecondaryLayout: false
    readonly property bool showSecondaryReadings: anyReadingAvailable || keepSecondaryLayout
    readonly property bool showCpuReading: displayMode !== 2 && showCpu && showSecondaryReadings
    readonly property bool showGpuReading: displayMode !== 2 && showGpu && showSecondaryReadings

    property var readings: ({
        totalPower: 0,
        cpuPower: 0,
        gpuPower: 0,
        totalAvailable: false,
        cpuAvailable: false,
        gpuAvailable: false,
        status: "unavailable",
        snapshotSequence: 0
    })
    readonly property real totalPower: readings.totalPower
    readonly property real cpuPower: readings.cpuPower
    readonly property real gpuPower: readings.gpuPower
    readonly property bool totalAvailable: readings.totalAvailable
    readonly property bool cpuAvailable: readings.cpuAvailable
    readonly property bool gpuAvailable: readings.gpuAvailable

    readonly property string readingsCommand: "bash -c 'for p in \"$HOME/.local/bin/mi-power-monitor-readings\" /usr/local/bin/mi-power-monitor-readings /usr/bin/mi-power-monitor-readings; do if [ -x \"$p\" ]; then exec \"$p\" \"$@\"; fi; done; if command -v mi-power-monitor-readings >/dev/null 2>&1; then exec mi-power-monitor-readings \"$@\"; fi; printf \"{\\\"total_power\\\":null,\\\"cpu_power\\\":null,\\\"gpu_power\\\":null,\\\"status\\\":\\\"backend-missing\\\",\\\"snapshot_at\\\":0}\\n\"' mi-power-monitor"
        + ((root.displayMode === 2 || !root.showCpu) ? " --no-cpu" : "")
        + ((root.displayMode === 2 || !root.showGpu) ? " --no-gpu" : "")

    preferredRepresentation: fullRepresentation
    activationTogglesExpanded: false
    Plasmoid.title: i18n("Mi Power Monitor")
    Plasmoid.icon: "preferences-system-power-management"
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    toolTipMainText: i18n("功耗")
    toolTipSubText: tooltipText()

    Timer {
        id: layoutGraceTimer
        interval: 5000
        repeat: false
        onTriggered: root.keepSecondaryLayout = false
    }

    onAnyReadingAvailableChanged: {
        if (anyReadingAvailable) {
            keepSecondaryLayout = true
            layoutGraceTimer.stop()
        } else if (keepSecondaryLayout) {
            layoutGraceTimer.restart()
        }
    }

    function isPower(value) {
        return typeof value === "number" && Number.isFinite(value) && value >= 0
    }

    function powerText(value, available) {
        if (!available)
            return "--W"
        const rounded = Math.round(value)
        return rounded > 9999 ? "9999+W" : rounded + "W"
    }

    function tooltipPower(value, available) {
        return available ? Number(value).toFixed(1) + " W" : "-- W"
    }

    function tooltipText() {
        if (readings.status === "backend-missing")
            return i18n("未找到功耗读取程序。请运行 KDE 仓库中的 install.sh 安装整套组件和后端。")
        if (readings.status === "unconfigured")
            return i18n("米家插座尚未配置或配置无效。请运行 KDE 仓库中的 install.sh 完成二维码配置。")
        return i18n("整机功耗   %1\nCPU        %2\nGPU        %3\n\n数据源\n整机       米家智能插座3\nCPU        RAPL\nGPU        NVIDIA",
                    tooltipPower(totalPower, totalAvailable),
                    tooltipPower(cpuPower, cpuAvailable),
                    tooltipPower(gpuPower, gpuAvailable))
    }

    function cycleDisplayMode() {
        plasmoid.configuration.displayMode = (displayMode + 1) % 3
    }

    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        interval: 1000
        connectedSources: [root.readingsCommand]

        onNewData: (sourceName, data) => {
            if (sourceName !== root.readingsCommand)
                return

            try {
                const result = JSON.parse(String(data.stdout || "").trim())
                if (result.status === "busy")
                    return
                const totalAvailable = root.isPower(result.total_power)
                const cpuAvailable = root.isPower(result.cpu_power)
                const gpuAvailable = root.isPower(result.gpu_power)
                const snapshotSequence = Number(result.snapshot_sequence || 0)
                if (snapshotSequence > 0 && snapshotSequence < root.readings.snapshotSequence)
                    return

                // Replace the complete snapshot in one assignment so every label
                // repaints from the same polling cycle.
                root.readings = {
                    totalPower: totalAvailable ? result.total_power : root.totalPower,
                    cpuPower: cpuAvailable ? result.cpu_power : root.cpuPower,
                    gpuPower: gpuAvailable ? result.gpu_power : root.gpuPower,
                    totalAvailable: totalAvailable,
                    cpuAvailable: cpuAvailable,
                    gpuAvailable: gpuAvailable,
                    status: String(result.status || "unavailable"),
                    snapshotSequence: snapshotSequence
                }
            } catch (error) {
                root.readings = {
                    totalPower: root.totalPower,
                    cpuPower: root.cpuPower,
                    gpuPower: root.gpuPower,
                    totalAvailable: false,
                    cpuAvailable: false,
                    gpuAvailable: false,
                    status: "unavailable",
                    snapshotSequence: root.readings.snapshotSequence
                }
            }
        }
    }

    fullRepresentation: Item {
        id: panelContent

        implicitWidth: panelRow.implicitWidth
        implicitHeight: panelRow.implicitHeight
        Layout.minimumWidth: implicitWidth
        Layout.preferredWidth: implicitWidth
        Layout.minimumHeight: 0
        Layout.preferredHeight: implicitHeight

    RowLayout {
        id: panelRow
        anchors.centerIn: parent
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Icon {
            source: Qt.resolvedUrl("../images/power.svg")
            color: Kirigami.Theme.highlightColor
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
            Layout.alignment: Qt.AlignVCenter
        }

        PlasmaComponents.Label {
            id: totalLabel
            text: root.powerText(root.totalPower, root.totalAvailable)
            Layout.minimumWidth: totalMetrics.width
            Layout.preferredWidth: totalMetrics.width
            Layout.maximumWidth: totalMetrics.width
            Layout.alignment: Qt.AlignVCenter
            horizontalAlignment: Text.AlignLeft
            opacity: root.totalAvailable ? 1.0 : 0.68
        }

        TextMetrics {
            id: totalMetrics
            font: totalLabel.font
            text: "9999+W"
        }

        PlasmaComponents.Label {
            visible: root.showCpuReading
            text: "·"
            opacity: 0.35
            Layout.alignment: Qt.AlignVCenter
        }

        PlasmaComponents.Label {
            id: cpuLabel
            visible: root.showCpuReading
            text: root.displayMode === 0
                ? i18n("CPU %1", root.powerText(root.cpuPower, root.cpuAvailable))
                : root.powerText(root.cpuPower, root.cpuAvailable)
            Layout.minimumWidth: root.displayMode === 0 ? cpuFullMetrics.width : cpuCompactMetrics.width
            Layout.preferredWidth: Layout.minimumWidth
            Layout.maximumWidth: Layout.minimumWidth
            Layout.alignment: Qt.AlignVCenter
            opacity: root.cpuAvailable ? 0.72 : 0.52
        }

        TextMetrics {
            id: cpuFullMetrics
            font: cpuLabel.font
            text: "CPU 9999+W"
        }

        TextMetrics {
            id: cpuCompactMetrics
            font: cpuLabel.font
            text: "9999+W"
        }

        PlasmaComponents.Label {
            visible: root.showGpuReading
            text: "·"
            opacity: 0.35
            Layout.alignment: Qt.AlignVCenter
        }

        PlasmaComponents.Label {
            id: gpuLabel
            visible: root.showGpuReading
            text: root.displayMode === 0
                ? i18n("GPU %1", root.powerText(root.gpuPower, root.gpuAvailable))
                : root.powerText(root.gpuPower, root.gpuAvailable)
            Layout.minimumWidth: root.displayMode === 0 ? gpuFullMetrics.width : gpuCompactMetrics.width
            Layout.preferredWidth: Layout.minimumWidth
            Layout.maximumWidth: Layout.minimumWidth
            Layout.alignment: Qt.AlignVCenter
            opacity: root.gpuAvailable ? 0.72 : 0.52
        }

        TextMetrics {
            id: gpuFullMetrics
            font: gpuLabel.font
            text: "GPU 9999+W"
        }

        TextMetrics {
            id: gpuCompactMetrics
            font: gpuLabel.font
            text: "9999+W"
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        onClicked: root.cycleDisplayMode()
    }
    }
}
