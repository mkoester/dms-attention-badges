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

    // ── herdr provider ──────────────────────────────────────────────────────
    // Polls rather than subscribing to the socket's event stream: a poll is
    // stateless, so a herdr restart, a dropped connection or a missed event all
    // heal on the next tick instead of leaving the badge silently frozen.
    readonly property bool herdrEnabled: targets.some(function (t) {
        return t.provider === "herdr";
    })
    readonly property int herdrPollSeconds: pluginData.herdrPollSeconds || 3
    // blocked = waiting for input, done = waiting for review. Both are your turn.
    readonly property var herdrStatuses: pluginData.herdrIncludeDone === false ? ["blocked"] : ["blocked", "done"]

    function _applyHerdrBuckets(buckets) {
        const next = Rules.setTargetBuckets(state, "herdr", buckets);
        if (JSON.stringify(next.targets.herdr) === JSON.stringify(state.targets.herdr))
            return;
        state = next;
        _persist();
    }

    // Last poll, reported by status(). Without this a herdr badge stuck at 0 is
    // indistinguishable between "nothing is waiting", "the command failed" and
    // "the output parsed but has a shape I did not expect" — three different bugs.
    property var herdrLastPoll: ({ at: 0, bytes: 0, parsed: false, agents: 0, statuses: "", error: "never polled" })

    Process {
        id: herdrSnapshot
        command: ["herdr", "api", "snapshot"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                let poll = { at: Date.now(), bytes: text.length, parsed: false, agents: 0, statuses: "", error: "" };
                let snapshot = null;
                try {
                    snapshot = JSON.parse(text);
                    poll.parsed = true;
                } catch (e) {
                    // herdr not running, or output that is not JSON. Treat as
                    // "nothing is waiting" rather than holding stale entries — the
                    // next successful poll restores them within seconds.
                    poll.error = "not JSON: " + text.slice(0, 120);
                    root.herdrLastPoll = poll;
                    root._applyHerdrBuckets({});
                    return;
                }

                const inner = Rules.unwrapSnapshot(snapshot);
                const agents = (inner && inner.agents) || [];
                poll.agents = agents.length;
                let seen = {};
                agents.forEach(function (a) {
                    const s = a.agent_status || "(none)";
                    seen[s] = (seen[s] || 0) + 1;
                });
                poll.statuses = Object.keys(seen).map(function (k) { return k + "=" + seen[k]; }).join(" ");
                if (!inner)
                    poll.error = "no snapshot found; top-level keys: " + Object.keys(snapshot || {}).join(",");

                root.herdrLastPoll = poll;
                root._applyHerdrBuckets(Rules.herdrBuckets(snapshot, root.herdrStatuses));
            }
        }
    }

    Timer {
        interval: root.herdrPollSeconds * 1000
        repeat: true
        running: root.herdrEnabled
        triggeredOnStart: true
        onTriggered: {
            if (!herdrSnapshot.running)
                herdrSnapshot.running = true;
        }
    }

    function _checkFocus() {
        const appId = ToplevelManager.activeToplevel?.appId ?? "";
        const target = Rules.targetForWindowClass(targets, appId);
        // A state target owns its own contents; clearing it here would only be
        // undone by the next poll a moment later, which reads as a flicker.
        if (target && target.mode !== "state")
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
                const how = t.mode === "state" ? "state via " + t.provider : "counted, clears on focus of " + t.windowClass;
                lines.push(t.label + " [" + how + "]: " + Rules.totalFor(root.state, t.id));
                for (let b = 0; b < buckets.length; b++)
                    lines.push("    " + buckets[b].count + "  " + buckets[b].name);
            }
            lines.push("lastSeen: " + new Date(root.state.lastSeenTs).toISOString());
            if (root.herdrEnabled) {
                const p = root.herdrLastPoll;
                lines.push("herdr poll: " + (p.at ? new Date(p.at).toISOString() : "never") + ", " + p.bytes + " bytes, parsed=" + p.parsed + ", agents=" + p.agents);
                lines.push("herdr statuses seen: " + (p.statuses || "(none)"));
                lines.push("herdr watching: " + root.herdrStatuses.join(", "));
                if (p.error)
                    lines.push("herdr error: " + p.error);
            }
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
