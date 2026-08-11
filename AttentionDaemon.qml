import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Modules.Plugins
import "Rules.js" as Rules

// Owns the badge state. Runs whether or not the bar widget is placed, so counting
// never depends on the widget being visible.
//
// Two inputs: DMS's notification history (what happened) and the focused window
// (when you looked). State is persisted through PluginService so a shell restart
// does not silently zero every badge.
PluginComponent {
    id: root

    readonly property string stateKey: "badgeState"

    property var state: Rules.emptyState()
    property var targets: Rules.defaultTargets().filter(function (t) {
        // pluginData is {} until settings are saved once, so default to enabled.
        return root.pluginData["enable_" + t.id] !== false;
    })

    function _persist() {
        if (pluginService)
            pluginService.savePluginState(pluginId, stateKey, state);
    }

    function ingest() {
        const next = Rules.applyHistory(state, targets, NotificationService.historyList);
        if (next === state)
            return;
        state = next;
        _persist();
    }

    function clearTarget(targetId) {
        if (Rules.totalFor(state, targetId) === 0)
            return;
        state = Rules.clearTarget(state, targetId);
        _persist();
    }

    function clearBucket(targetId, bucketName) {
        state = Rules.clearBucket(state, targetId, bucketName);
        _persist();
    }

    function clearAll() {
        state = { lastSeenTs: state.lastSeenTs, targets: {} };
        _persist();
    }

    function _checkFocus() {
        const appId = ToplevelManager.activeToplevel?.appId ?? "";
        const target = Rules.targetForWindowClass(targets, appId);
        if (target)
            clearTarget(target.id);
    }

    Connections {
        target: NotificationService
        function onHistoryListChanged() {
            root.ingest();
        }
    }

    Connections {
        target: ToplevelManager
        function onActiveToplevelChanged() {
            root._checkFocus();
        }
    }

    // Reachable from a normal terminal as:
    //   dms ipc call attentionBadges status
    //   dms ipc call attentionBadges clear
    // Useful because the badge is otherwise only observable by waiting for mail.
    IpcHandler {
        target: "attentionBadges"

        function status(): string {
            // The focused class is the whole reset mechanism, and a wrong one fails
            // silently — report it rather than making the next person guess.
            const appId = ToplevelManager.activeToplevel?.appId ?? "";
            let lines = ["focused: " + (appId || "(none)")];
            for (let i = 0; i < root.targets.length; i++) {
                const t = root.targets[i];
                const buckets = Rules.bucketList(root.state, t.id);
                lines.push(t.label + " (" + t.windowClass + "): " + Rules.totalFor(root.state, t.id));
                for (let b = 0; b < buckets.length; b++)
                    lines.push("    " + buckets[b].count + "  " + buckets[b].name);
            }
            lines.push("lastSeen: " + new Date(root.state.lastSeenTs).toISOString());
            return lines.join("\n");
        }

        function clear(): string {
            root.clearAll();
            return "cleared";
        }

        function clearOne(targetId: string): string {
            root.clearTarget(targetId);
            return "cleared " + targetId;
        }
    }

    Component.onCompleted: {
        const saved = pluginService ? pluginService.loadPluginState(pluginId, stateKey, null) : null;
        if (saved && typeof saved.lastSeenTs === "number") {
            state = { lastSeenTs: saved.lastSeenTs, targets: saved.targets || {} };
        } else {
            // First run: start from now. Folding the stored history instead would
            // greet a new install with a badge of everything in the last 7 days.
            state = { lastSeenTs: Date.now(), targets: {} };
            _persist();
        }
        ingest();
        _checkFocus();
    }
}
