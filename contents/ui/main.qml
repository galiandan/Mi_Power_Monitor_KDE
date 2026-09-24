import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    property string powerText: "—"
    property string statusText: i18n("Waiting for reading…")
    property bool reading: false

    implicitWidth: layout.implicitWidth + PlasmaCore.Units.smallSpacing * 4
    implicitHeight: layout.implicitHeight + PlasmaCore.Units.smallSpacing * 2

    Plasmoid.title: i18n("Mi Power Monitor")
    Plasmoid.icon: "電源"
    Plasmoid.toolTipMainText: i18n("Mi Power Monitor")
    Plasmoid.toolTipSubText: statusText

    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            root.reading = false

            const exitCode = Number(data["exit code"])
            const output = String(data.stdout || "").trim()
            if (exitCode !== 0 || output.length === 0) {
                root.statusText = String(data.stderr || i18n("Could not read power" )).trim()
                return
            }

            try {
                const reading = JSON.parse(output)
                if (reading.available && reading.power !== null && reading.power !== undefined) {
                    root.powerText = Number(reading.power).toFixed(1)
                    root.statusText = i18n("Live power")
                } else {
                    root.statusText = reading.error || i18n("Power unavailable")
                }
            } catch (error) {
                root.statusText = i18n("Invalid response from xiaomi-power")
            }
        }
    }

    function readPower() {
        if (reading)
            return
        reading = true
        executable.connectSource("xiaomi-power --json")
    }

    Timer {
        interval: 2000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.readPower()
    }

    ColumnLayout {
        id: layout
        anchors.centerIn: parent
        spacing: PlasmaCore.Units.smallSpacing / 2

        RowLayout {
            spacing: PlasmaCore.Units.smallSpacing

            PlasmaCore.IconItem {
                source: "電源"
                width: PlasmaCore.Units.iconSizes.medium
                height: width
            }

            PlasmaComponents.Label {
                text: root.powerText
                font.pointSize: Math.max(PlasmaCore.Theme.defaultFont.pointSize + 3, 12)
                font.weight: Font.DemiBold
            }

            PlasmaComponents.Label {
                text: "W"
                opacity: 0.75
            }
        }

        PlasmaComponents.Label {
            Layout.fillWidth: true
            text: root.statusText
            opacity: 0.7
            font.pointSize: PlasmaCore.Theme.defaultFont.pointSize * 0.85
            elide: Text.ElideRight
        }
    }
}
