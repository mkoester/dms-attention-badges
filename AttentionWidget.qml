import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "Rules.js" as Rules

// Renders what the daemon counted. Deliberately has no logic of its own: the
// daemon is the single writer of the state, so the badge cannot disagree with
// itself when the widget is placed on two monitors.
PluginComponent {
    id: root

    layerNamespacePlugin: "attention-badges"

    readonly property string stateKey: "badgeState"
    readonly property string targetsKey: "renderTargets"
    readonly property bool hideWhenIdle: pluginData.hideWhenIdle !== false

    property var state: Rules.emptyState()
    // Published by the daemon, which owns the provider scan. The widget never
    // reads a provider file: two instances scanning the same directory could
    // disagree, and one of them would be wrong on every monitor it is placed on.
    // The list carries every valid provider; filtering to the enabled ones is
    // done here, because pluginData is available to every surface.
    property var allTargets: []

    readonly property var targets: allTargets.filter(function (t) {
        return root.pluginData["enable_" + t.id] !== false;
    })

    // Only targets with something pending, in the order they are configured.
    readonly property var active: targets.filter(function (t) {
        return Rules.totalFor(root.state, t.id) > 0;
    })
    readonly property bool idle: active.length === 0

    function reload() {
        const saved = pluginService ? pluginService.loadPluginState(pluginId, stateKey, null) : null;
        state = (saved && saved.targets) ? saved : Rules.emptyState();
        const published = pluginService ? pluginService.loadPluginState(pluginId, targetsKey, null) : null;
        allTargets = (published && published.targets) ? published.targets : [];
    }

    Connections {
        target: pluginService
        function onPluginStateChanged(changedPluginId) {
            if (changedPluginId === root.pluginId)
                root.reload();
        }
    }

    Component.onCompleted: reload()

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS

            Repeater {
                model: root.idle ? (root.hideWhenIdle ? [] : [null]) : root.active

                Row {
                    spacing: Theme.spacingXS
                    opacity: modelData ? 1 : 0.4

                    DankIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: modelData ? modelData.icon : "notifications_paused"
                        size: root.iconSize
                        color: modelData ? Theme.primary : Theme.widgetIconColor
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !!modelData
                        text: modelData ? Rules.totalFor(root.state, modelData.id) : ""
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                    }
                }
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            Repeater {
                model: root.idle ? (root.hideWhenIdle ? [] : [null]) : root.active

                Column {
                    spacing: 0

                    DankIcon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        name: modelData ? modelData.icon : "notifications_paused"
                        size: root.iconSize
                        color: modelData ? Theme.primary : Theme.widgetIconColor
                        opacity: modelData ? 1 : 0.4
                    }

                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: !!modelData
                        text: modelData ? Rules.totalFor(root.state, modelData.id) : ""
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                    }
                }
            }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            headerText: "Since you last looked"
            detailsText: root.idle ? "Nothing pending" : "Focus an app's window to clear its badge"
            showCloseButton: true

            Column {
                width: parent.width
                spacing: Theme.spacingM

                Repeater {
                    model: root.active

                    Column {
                        id: targetSection

                        readonly property var target: modelData

                        width: parent.width
                        spacing: Theme.spacingXS

                        Row {
                            spacing: Theme.spacingS

                            DankIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: targetSection.target.icon
                                size: Theme.fontSizeLarge
                                color: Theme.primary
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: targetSection.target.label
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                            }
                        }

                        Repeater {
                            model: Rules.bucketList(root.state, targetSection.target.id)

                            Row {
                                width: parent.width
                                spacing: Theme.spacingS

                                StyledText {
                                    width: Theme.fontSizeLarge * 2
                                    horizontalAlignment: Text.AlignRight
                                    text: modelData.count
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: modelData.name
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    popoutWidth: 360
    popoutHeight: 400

    // Right-click clears everything. Goes through the daemon's IPC handler rather
    // than writing the state here, so there is only ever one writer.
    pillRightClickAction: function () {
        Quickshell.execDetached(["dms", "ipc", "call", "attentionBadges", "clear"]);
    }
}
