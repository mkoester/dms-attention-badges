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
        description: "Panes whose agent is blocked, polled from herdr's own API. Needs no reset — a pane leaves the badge when its agent stops waiting, or while you are focused on it."
        defaultValue: true
    }

    SliderSetting {
        settingKey: "herdrPollSeconds"
        label: "herdr poll interval"
        description: "Seconds between `herdr api snapshot` calls."
        defaultValue: 3
        minimum: 1
        maximum: 30
        unit: "s"
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
