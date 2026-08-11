import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "attentionBadges"

    StyledText {
        width: parent.width
        text: "Watched apps"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "enable_thunderbird"
        label: "Thunderbird"
        description: "New mail per account, from Thunderbird's own notifications. Clears when a Thunderbird window is focused."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "enable_herdr"
        label: "herdr"
        description: "Agents reporting 'needs attention', bucketed by workspace and pane. Clears when the herdr window is focused."
        defaultValue: true
    }

    StyledText {
        width: parent.width
        text: "Appearance"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "hideWhenIdle"
        label: "Hide when nothing is pending"
        description: "Off shows a dimmed icon instead, which keeps the widget clickable when all badges are clear."
        defaultValue: true
    }
}
