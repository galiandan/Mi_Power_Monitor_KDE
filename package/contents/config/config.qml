import QtQuick
import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: i18n("显示")
        icon: "preferences-system-power-management"
        source: "configDisplay.qml"
    }
}
