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

    property var readings: ({
        totalPower: 0,
        cpuPower: 0,
        gpuPower: 0,
        totalAvailable: false,
        cpuAvailable: false,
        gpuAvailable: false
    })
    readonly property real totalPower: readings.totalPower
    readonly property real cpuPower: readings.cpuPower
    readonly property real gpuPower: readings.gpuPower
    readonly property bool totalAvailable: readings.totalAvailable
    readonly property bool cpuAvailable: readings.cpuAvailable
    readonly property bool gpuAvailable: readings.gpuAvailable

    readonly property string readingsCommand: "bash -c 'exec \"$HOME/.local/bin/mi-power-monitor-readings\"'"

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
        connectedSources: [root.readingsCommand]

        onNewData: (sourceName, data) => {
            if (sourceName !== root.readingsCommand)
                return

            try {
                const result = JSON.parse(String(data.stdout || "").trim())
                const totalAvailable = root.isPower(result.total_power)
                const cpuAvailable = root.isPower(result.cpu_power)
                const gpuAvailable = root.isPower(result.gpu_power)

                // Replace the complete snapshot in one assignment so every label
                // repaints from the same polling cycle.
                root.readings = {
                    totalPower: totalAvailable ? result.total_power : root.totalPower,
                    cpuPower: cpuAvailable ? result.cpu_power : root.cpuPower,
                    gpuPower: gpuAvailable ? result.gpu_power : root.gpuPower,
                    totalAvailable: totalAvailable,
                    cpuAvailable: cpuAvailable,
                    gpuAvailable: gpuAvailable
                }
            } catch (error) {
                root.readings = {
                    totalPower: root.totalPower,
                    cpuPower: root.cpuPower,
                    gpuPower: root.gpuPower,
                    totalAvailable: false,
                    cpuAvailable: false,
                    gpuAvailable: false
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
