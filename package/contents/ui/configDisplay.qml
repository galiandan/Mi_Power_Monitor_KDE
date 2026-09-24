import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Kirigami.Page {
    id: page
    title: i18n("显示")

    property alias cfg_displayMode: displayMode.currentIndex
    property alias cfg_showCpu: showCpu.checked
    property alias cfg_showGpu: showGpu.checked
    property int cfg_displayModeDefault: 0
    property bool cfg_showCpuDefault: true
    property bool cfg_showGpuDefault: true

    Kirigami.FormLayout {
        anchors.left: parent.left
        anchors.right: parent.right

        QQC2.ComboBox {
            id: displayMode
            Kirigami.FormData.label: i18n("显示模式：")
            model: [i18n("完整"), i18n("紧凑"), i18n("仅整机")]
        }

        QQC2.CheckBox {
            id: showCpu
            text: i18n("显示 CPU 功耗")
        }

        QQC2.CheckBox {
            id: showGpu
            text: i18n("显示 GPU 功耗")
        }
    }
}
