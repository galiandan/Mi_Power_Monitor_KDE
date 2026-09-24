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
    readonly property bool showCpuReading: displayMode !== 2 && showCpu && anyReadingAvailable
    readonly property bool showGpuReading: displayMode !== 2 && showGpu && anyReadingAvailable

    property real totalPower: 0
    property real cpuPower: 0
    property real gpuPower: 0
    property bool totalAvailable: false
    property bool cpuAvailable: false
    property bool gpuAvailable: false

    readonly property string totalCommand: "bash -c 'exec \"$HOME/.local/bin/xiaomi-power\" --json'"
    readonly property string sensorsCommand: "bash -c 'exec \"$HOME/.local/bin/mi-power-monitor-sensors\"'"

    preferredRepresentation: fullRepresentation
    activationTogglesExpanded: false
    Plasmoid.title: i18n("Mi Power Monitor")
    Plasmoid.icon: "preferences-system-power-management"
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    toolTipMainText: i18n("功耗")
    toolTipSubText: tooltipText()

    function isPower(value) {
        return typeof value === "number" && Number.isFinite(value) && value >= 0
    }

    function powerText(value, available) {
        return available ? Math.round(value) + "W" : "--W"
    }

    function tooltipPower(value, available) {
        return available ? Number(value).toFixed(1) + " W" : "-- W"
    }

    function tooltipText() {
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
        connectedSources: [root.totalCommand, root.sensorsCommand]

        onNewData: (sourceName, data) => {
            const output = String(data.stdout || "").trim()

            if (sourceName === root.totalCommand) {
                try {
                    const result = JSON.parse(output)
                    root.totalAvailable = result.available === true && root.isPower(result.power)
                    if (root.totalAvailable)
                        root.totalPower = result.power
                } catch (error) {
                    root.totalAvailable = false
                }
                return
            }

            if (sourceName === root.sensorsCommand) {
                try {
                    const result = JSON.parse(output)
                    root.cpuAvailable = root.isPower(result.cpu_power)
                    root.gpuAvailable = root.isPower(result.gpu_power)
                    if (root.cpuAvailable)
                        root.cpuPower = result.cpu_power
                    if (root.gpuAvailable)
                        root.gpuPower = result.gpu_power
                } catch (error) {
                    root.cpuAvailable = false
                    root.gpuAvailable = false
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
        Layout.minimumHeight: implicitHeight
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
            text: "8888W"
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
            text: "CPU 888W"
        }

        TextMetrics {
            id: cpuCompactMetrics
            font: cpuLabel.font
            text: "888W"
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
            text: "GPU 888W"
        }

        TextMetrics {
            id: gpuCompactMetrics
            font: gpuLabel.font
            text: "888W"
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        onClicked: root.cycleDisplayMode()
    }
    }
}
