import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "attentionBadges"

    readonly property string targetsKey: "renderTargets"

    // The daemon owns the provider scan and publishes the result; this page only
    // draws a toggle per discovered provider. It deliberately does not scan the
    // directory itself — two scanners could disagree, and the one the user is
    // looking at would not be the one doing the counting.
    property var discovered: []
    property var invalid: []

    function reload() {
        const published = pluginService ? pluginService.loadPluginState(pluginId, targetsKey, null) : null;
        discovered = (published && published.targets) ? published.targets : [];
        invalid = (published && published.invalid) ? published.invalid : [];
    }

    Connections {
        target: pluginService
        function onPluginStateChanged(changedPluginId) {
            if (changedPluginId === root.pluginId)
                root.reload();
        }
    }

    // pluginService is assigned after construction, so onCompleted alone would
    // read null and leave the page permanently empty.
    onPluginServiceChanged: reload()
    Component.onCompleted: reload()

    StyledText {
        width: parent.width
        text: "Providers"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        wrapMode: Text.WordWrap
        text: "Each watched app is a JSON file in ~/.config/DankMaterialShell/attention-providers/. "
            + "Nothing is watched until you add one — see the plugin's README for the format, and "
            + "providers/ in its repository for working examples."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    // No providers is the normal state of a fresh install, not a fault — say so,
    // because an empty page with no explanation reads as a broken plugin.
    StyledText {
        width: parent.width
        wrapMode: Text.WordWrap
        visible: root.discovered.length === 0 && root.invalid.length === 0
        text: "No provider files found."
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
    }

    Repeater {
        model: root.discovered

        ToggleSetting {
            required property var modelData

            settingKey: "enable_" + modelData.id
            label: modelData.label
            description: (modelData.mode === "state"
                ? "Replaced on every poll; needs no reset."
                : "Counts notifications; cleared when you focus its window.")
                + "  (" + modelData.source + ")"
            defaultValue: true
        }
    }

    // A provider that failed to load looks exactly like an app that has not
    // notified yet, so it is listed here with its reason rather than skipped.
    StyledText {
        width: parent.width
        visible: root.invalid.length > 0
        text: "Provider files with errors"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.error
    }

    Repeater {
        model: root.invalid

        StyledText {
            required property var modelData

            width: parent.width
            wrapMode: Text.WordWrap
            text: modelData.source + ": " + modelData.errors.join("; ")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.error
        }
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
