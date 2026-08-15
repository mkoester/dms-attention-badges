import QtQuick
import Qt.labs.folderlistmodel
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
// This file knows nothing about any particular application. Everything watched is
// described by a JSON file in the providers directory; see README.md for the
// format. The daemon's job is to discover those files, feed the targets they
// describe from two inputs — DMS's notification history (what happened) and the
// focused window (when you looked) — and persist the result through PluginService
// so a shell restart does not silently zero every badge.
PluginComponent {
    id: root

    readonly property string stateKey: "badgeState"
    // The widget is a separate instance and cannot see the daemon's scan, so the
    // daemon publishes the rendered target list here. Same reason the daemon owns
    // the counts: one writer, everyone else listens.
    readonly property string targetsKey: "renderTargets"

    // A sibling of the plugins directory, not a subdirectory of the plugin: the
    // plugin directory is usually a symlink to a git checkout, and user provider
    // files must not land inside it.
    //
    // Paths.strip, not StandardPaths directly: StandardPaths.writableLocation
    // returns a URL (`file:///home/…`), so concatenating "file://" onto it yields
    // `file://file:///home/…`. FolderListModel does not report that as an error —
    // it silently falls back to the process working directory and happily
    // enumerates whatever is there, which reads as a real (and wrong) answer.
    readonly property string providersDir: Paths.strip(Paths.config) + "/attention-providers"

    property var state: Rules.emptyState()

    // ── Provider discovery ──────────────────────────────────────────────────
    // Filename -> parsed JSON, and filename -> why it was rejected. Both are
    // reported by status() and by the settings page: a provider file that fails
    // to load looks exactly like an app that has not notified yet, so it has to
    // be said out loud.
    property var providerData: ({})
    property var providerLoadErrors: ({})

    // Every valid provider, enabled or not — the settings page lists all of them.
    property var allTargets: []
    property var invalidProviders: []

    // The ones actually being watched. pluginData is {} until settings are saved
    // once, so a provider defaults to enabled.
    readonly property var targets: allTargets.filter(function (t) {
        return root.pluginData["enable_" + t.id] !== false;
    })

    readonly property var commandTargets: targets.filter(function (t) {
        return !!t.command;
    })

    // Every VALID provider, enabled or not, plus whatever failed to load — not
    // the match rules or commands, which no other surface needs.
    //
    // Publishing only the enabled ones would be the obvious thing and is a trap:
    // the settings page draws its toggles from this list, so a provider disabled
    // once would disappear from it and could never be switched back on.
    function _publishTargets() {
        if (!pluginService)
            return;
        pluginService.savePluginState(pluginId, targetsKey, {
            targets: allTargets.map(function (t) {
                return { id: t.id, label: t.label, icon: t.icon, mode: t.mode, source: t.source };
            }),
            invalid: invalidProviders
        });
    }

    onAllTargetsChanged: _publishTargets()
    onInvalidProvidersChanged: _publishTargets()

    readonly property var env: ({
            HOME: Quickshell.env("HOME") || "",
            XDG_STATE_HOME: Quickshell.env("XDG_STATE_HOME") || "",
            XDG_CONFIG_HOME: Quickshell.env("XDG_CONFIG_HOME") || "",
            XDG_CACHE_HOME: Quickshell.env("XDG_CACHE_HOME") || ""
        })

    function _rebuildTargets() {
        // Sorted by source so "first wins" on a duplicate id is deterministic
        // rather than depending on the order the directory happened to enumerate.
        const files = Object.keys(providerData).sort().map(function (source) {
            const entry = providerData[source];
            return { source: source, dir: entry.dir, data: entry.data };
        });
        const built = Rules.buildTargets(files);

        let invalid = built.invalid.slice();
        Object.keys(providerLoadErrors).sort().forEach(function (name) {
            invalid.push({ source: name, errors: [providerLoadErrors[name]] });
        });

        allTargets = built.targets;
        invalidProviders = invalid;

        // A provider file that was deleted must not leave its counts behind.
        const pruned = Rules.pruneOrphans(state, built.targets);
        if (pruned !== state) {
            state = pruned;
            _persist();
        }
    }

    // `source` is the path relative to the providers directory — `herdr.json` for
    // a flat file, `herdr/provider.json` for a directory provider. It must NOT be
    // the bare filename: every directory provider is called provider.json, so
    // filenames collide the moment there is more than one clone.
    function _providerLoaded(source, dir, text) {
        let data = null;
        try {
            data = JSON.parse(text);
        } catch (e) {
            let errs = Object.assign({}, providerLoadErrors);
            errs[source] = "not valid JSON: " + String(e.message || e);
            providerLoadErrors = errs;
            let d = Object.assign({}, providerData);
            delete d[source];
            providerData = d;
            _rebuildTargets();
            return;
        }
        let errs = Object.assign({}, providerLoadErrors);
        delete errs[source];
        providerLoadErrors = errs;
        let d = Object.assign({}, providerData);
        d[source] = { data: data, dir: dir || "" };
        providerData = d;
        _rebuildTargets();
    }

    function _providerFailed(source, reason) {
        let d = Object.assign({}, providerData);
        delete d[source];
        providerData = d;
        let errs = Object.assign({}, providerLoadErrors);
        errs[source] = reason;
        providerLoadErrors = errs;
        _rebuildTargets();
    }

    // A subdirectory with no provider.json is simply not a provider — somebody's
    // notes, a stray checkout. It gets a stage note so it is visible, and must
    // NOT become an "invalid provider": reporting an unrelated directory as a
    // broken provider is the same false accusation as the package.json incident.
    function _notAProvider(source) {
        let d = Object.assign({}, providerData);
        delete d[source];
        providerData = d;
        let errs = Object.assign({}, providerLoadErrors);
        delete errs[source];
        providerLoadErrors = errs;
        _rebuildTargets();
    }

    FolderListModel {
        id: providerFolder
        folder: Paths.toFileUrl(root.providersDir)
        nameFilters: ["*.json"]
        showDirs: false
        showDotAndDotDot: false
        sortField: FolderListModel.Name
    }

    // Belt and braces for the fallback described above: whatever the model
    // enumerates, only accept files that are actually inside the directory we
    // asked for. Without this the failure mode is not an error but a confident
    // wrong answer — a stray package.json reported as a broken provider.
    function _isOurs(filePath) {
        return typeof filePath === "string" && filePath.indexOf(root.providersDir + "/") === 0;
    }

    // Per-file lifecycle, reported verbatim by status(). This exists because
    // "0 valid, 0 invalid" alongside "2 *.json seen" was un-diagnosable: it is
    // equally consistent with no delegate being created, a delegate created with
    // an empty path, a load still in flight, and a load that succeeded into a
    // rebuild that produced nothing. Four different bugs, one identical line.
    // Report the stage each file reached rather than only the final tally.
    property var providerStage: ({})

    function _stage(key, value) {
        let next = Object.assign({}, providerStage);
        next[key] = value;
        providerStage = next;
    }

    Instantiator {
        model: providerFolder
        delegate: FileView {
            id: providerFile
            required property string fileName
            required property string filePath

            // Loading nothing is the correct response to a file we did not ask
            // for; the guard below reports it rather than swallowing it.
            path: root._isOurs(providerFile.filePath) ? providerFile.filePath : ""
            watchChanges: true
            blockLoading: false

            Component.onCompleted: {
                if (root._isOurs(providerFile.filePath))
                    root._stage(providerFile.fileName, "delegate created, loading " + providerFile.filePath);
                else
                    root._stage(providerFile.fileName || providerFile.filePath,
                        "STRAY — outside " + root.providersDir + ": " + providerFile.filePath);
            }

            onLoaded: {
                root._stage(providerFile.fileName, "loaded");
                // A flat file has no directory of its own, so no $PROVIDER_DIR.
                root._providerLoaded(providerFile.fileName, "", text());
            }
            onLoadFailed: {
                root._stage(providerFile.fileName, "load failed");
                root._providerFailed(providerFile.fileName, "unreadable");
            }
        }
    }

    // ── Directory providers ─────────────────────────────────────────────────
    // The normal install: each provider is a git clone in its own subdirectory,
    // carrying provider.json plus whatever helper scripts it needs. A fixed
    // filename rather than "any *.json one level down", so a repo's README,
    // package.json or fixtures can never be mistaken for a provider.
    readonly property string providerFileName: "provider.json"

    FolderListModel {
        id: providerDirs
        folder: Paths.toFileUrl(root.providersDir)
        showDirs: true
        showFiles: false
        showDotAndDotDot: false
        showHidden: false
        sortField: FolderListModel.Name
    }

    Instantiator {
        model: providerDirs
        delegate: FileView {
            id: providerDirFile
            required property string fileName
            required property string filePath

            readonly property string source: providerDirFile.fileName + "/" + root.providerFileName

            path: root._isOurs(providerDirFile.filePath)
                ? providerDirFile.filePath + "/" + root.providerFileName
                : ""
            watchChanges: true
            blockLoading: false

            Component.onCompleted: {
                if (root._isOurs(providerDirFile.filePath))
                    root._stage(providerDirFile.source, "delegate created, loading " + path);
                else
                    root._stage(providerDirFile.fileName,
                        "STRAY — outside " + root.providersDir + ": " + providerDirFile.filePath);
            }

            onLoaded: {
                root._stage(providerDirFile.source, "loaded");
                root._providerLoaded(providerDirFile.source, providerDirFile.filePath, text());
            }
            // Absent provider.json is the ordinary case for a directory that is
            // not a provider at all — a note, not a fault.
            onLoadFailed: {
                root._stage(providerDirFile.source, "no " + root.providerFileName + " — not a provider directory");
                root._notAProvider(providerDirFile.source);
            }
        }
    }

    // A late rescan. The provider files are read asynchronously and the folder
    // models resolve asynchronously too, so a shell restart can leave the scan
    // half-finished; nudging both re-runs it without touching anything else.
    function rescan() {
        const url = Paths.toFileUrl(root.providersDir);
        providerFolder.folder = "";
        providerFolder.folder = url;
        providerDirs.folder = "";
        providerDirs.folder = url;
    }

    // $PROVIDER_DIR is per target, so every expansion needs the target's own
    // directory folded into the environment.
    function _envFor(target) {
        return Object.assign({}, env, { PROVIDER_DIR: (target && target.dir) || "" });
    }

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

    // ── Per-bucket resets ───────────────────────────────────────────────────
    // Optional, and per target. Without the file, focusing the app clears every
    // bucket — the only thing the compositor makes possible, since it reports
    // that a window gained focus and nothing about what you looked at inside it.
    // With it, a helper says which bucket you opened and only that one clears.
    property var perBucketLive: ({})

    readonly property var perBucketTargets: targets.filter(function (t) {
        return !!t.perBucketFile;
    })

    function _setPerBucketLive(targetId, live) {
        if (!!perBucketLive[targetId] === !!live)
            return;
        let next = Object.assign({}, perBucketLive);
        next[targetId] = !!live;
        perBucketLive = next;
    }

    function _visitsLoaded(targetId, text) {
        let payload = null;
        try {
            payload = JSON.parse(text);
        } catch (e) {
            _setPerBucketLive(targetId, false);
            return;
        }
        const live = Rules.bridgeIsLive(payload, Date.now());
        _setPerBucketLive(targetId, live);
        if (!live)
            return;
        const next = Rules.applyVisits(root.state, targetId, payload);
        if (JSON.stringify(next) === JSON.stringify(root.state))
            return;
        root.state = next;
        root._persist();
    }

    Instantiator {
        model: root.perBucketTargets
        delegate: FileView {
            id: visitsFile
            required property var modelData

            path: Rules.expandPath(visitsFile.modelData.perBucketFile, root._envFor(visitsFile.modelData))
            watchChanges: true
            blockLoading: false

            onLoaded: root._visitsLoaded(visitsFile.modelData.id, text())
            // No file at all is the normal case for someone who never installed
            // the helper — not an error, and the reason the fallback exists.
            onLoadFailed: error => root._setPerBucketLive(visitsFile.modelData.id, false)
        }
    }

    // ── Command providers ───────────────────────────────────────────────────
    // Polled rather than subscribed to: a poll is stateless, so a crashed
    // producer, a dropped connection or a missed event all heal on the next tick
    // instead of leaving the badge silently frozen. The cost is up to one
    // interval of lag and one process spawn per tick.
    //
    // The contract is the command's stdout: {"buckets": {"<name>": <count>}}.
    // Anything else clears that target for the tick rather than holding stale
    // entries, and the reason is recorded in lastPoll.

    // targetId -> what the last poll actually saw. Without this a badge stuck at
    // 0 is indistinguishable between "nothing is waiting", "the command failed"
    // and "the output parsed but had a shape I did not expect" — three different
    // bugs that render identically.
    property var lastPoll: ({})

    function _mergePoll(targetId, fields) {
        let next = Object.assign({}, lastPoll);
        next[targetId] = Object.assign({}, next[targetId] || {}, fields);
        lastPoll = next;
    }

    // Three separate signals record a poll, because they fail independently and
    // an earlier version recorded only the first. A command that could not be
    // spawned at all produced no stdout, so nothing was written, and status()
    // said "poll: never" — which is exactly what "the timer never fired" says.
    // Two unrelated bugs with one symptom is the thing to design against here.
    function _pollStarted(targetId) {
        _mergePoll(targetId, { startedAt: Date.now(), gotOutput: false, stderr: "", exitCode: null });
    }

    function _commandFinished(targetId, text) {
        const result = Rules.parseCommandOutput(text);
        _mergePoll(targetId, {
            at: Date.now(),
            gotOutput: true,
            bytes: (text || "").length,
            buckets: Object.keys(result.buckets).length,
            error: result.error || ""
        });
        _applyBuckets(targetId, result.buckets);
    }

    function _commandExited(targetId, exitCode) {
        const prev = lastPoll[targetId] || {};
        _mergePoll(targetId, { exitCode: exitCode, exitedAt: Date.now() });
        if (prev.gotOutput)
            return;
        // Exited having printed nothing: could not be spawned (a command not on
        // the unit's PATH is the usual one), crashed, or printed only stderr.
        _mergePoll(targetId, {
            at: Date.now(),
            bytes: 0,
            buckets: 0,
            error: "produced no output; exit code " + exitCode
        });
        _applyBuckets(targetId, {});
    }

    function _commandStderr(targetId, text) {
        const trimmed = (text || "").trim();
        if (trimmed === "")
            return;
        let next = Object.assign({}, lastPoll);
        let entry = Object.assign({}, next[targetId] || {});
        entry.stderr = trimmed.slice(0, 300);
        next[targetId] = entry;
        lastPoll = next;
    }

    function _applyBuckets(targetId, buckets) {
        const next = Rules.setTargetBuckets(state, targetId, buckets);
        if (JSON.stringify(next.targets[targetId]) === JSON.stringify(state.targets[targetId]))
            return;
        state = next;
        _persist();
    }

    Instantiator {
        model: root.commandTargets
        delegate: Timer {
            id: pollTimer
            required property var modelData

            interval: Math.max(1, pollTimer.modelData.intervalSeconds) * 1000
            repeat: true
            running: true
            triggeredOnStart: true

            property Process proc: Process {
                command: pollTimer.modelData.command.map(function (a) {
                    return Rules.expandPath(a, root._envFor(pollTimer.modelData));
                })
                running: false
                stdout: StdioCollector {
                    onStreamFinished: root._commandFinished(pollTimer.modelData.id, text)
                }
                stderr: StdioCollector {
                    onStreamFinished: root._commandStderr(pollTimer.modelData.id, text)
                }
                onExited: (exitCode, exitStatus) => root._commandExited(pollTimer.modelData.id, exitCode)
            }

            onTriggered: {
                if (proc.running)
                    return;
                root._pollStarted(pollTimer.modelData.id);
                proc.running = true;
            }
        }
    }

    // ── Focus reset ─────────────────────────────────────────────────────────
    function _checkFocus() {
        const appId = ToplevelManager.activeToplevel?.appId ?? "";
        const target = Rules.targetForWindowClass(targets, appId);
        if (!target)
            return;
        // A state target owns its own contents; clearing it here would only be
        // undone by the next poll a moment later, which reads as a flicker.
        if (target.mode === "state")
            return;
        // When a per-bucket helper is live it reports which bucket you opened, so
        // a blanket clear here would throw away exactly the precision it adds.
        if (target.perBucketFile && perBucketLive[target.id])
            return;
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
    // Useful because the badge is otherwise only observable by waiting for events.
    IpcHandler {
        target: "attentionBadges"

        function status(): string {
            // The focused class is the whole reset mechanism, and a wrong one fails
            // silently — report it rather than making the next person guess.
            const appId = ToplevelManager.activeToplevel?.appId ?? "";
            let lines = ["focused: " + (appId || "(none)")];
            const names = ["Null", "Ready", "Loading"];
            lines.push("providers dir: " + root.providersDir
                + " (" + providerFolder.count + " flat *.json, model " + (names[providerFolder.status] || providerFolder.status)
                + "; " + providerDirs.count + " subdirs, model " + (names[providerDirs.status] || providerDirs.status) + ")");
            lines.push("providers: " + root.allTargets.length + " valid, " + root.invalidProviders.length + " invalid");

            // Every file the model enumerated, and how far it got. "0 valid,
            // 0 invalid" with files present means every one of these stalled
            // before reaching a verdict — which stage says which bug.
            const stageKeys = Object.keys(root.providerStage).sort();
            for (let s = 0; s < stageKeys.length; s++)
                lines.push("  " + stageKeys[s] + ": " + root.providerStage[stageKeys[s]]);
            if (providerFolder.count + providerDirs.count > 0 && stageKeys.length === 0)
                lines.push("  (models list entries but no delegate was ever created — try: dms ipc call attentionBadges rescan)");

            for (let i = 0; i < root.allTargets.length; i++) {
                const t = root.allTargets[i];
                const enabled = root.pluginData["enable_" + t.id] !== false;
                let how;
                if (t.mode === "state")
                    how = "state via " + t.command.join(" ");
                else if (t.perBucketFile && root.perBucketLive[t.id])
                    how = "counted, clears per bucket via " + Rules.expandPath(t.perBucketFile, root._envFor(t));
                else if (t.command)
                    how = "counted via " + t.command.join(" ");
                else
                    how = "counted, clears on focus of " + t.windowClass;
                if (!enabled)
                    how = "DISABLED; would be " + how;

                lines.push(t.label + " (" + t.id + ", " + t.source + ") [" + how + "]: " + Rules.totalFor(root.state, t.id));
                const buckets = Rules.bucketList(root.state, t.id);
                for (let b = 0; b < buckets.length; b++)
                    lines.push("    " + buckets[b].count + "  " + buckets[b].name);

                if (t.command) {
                    lines.push("    command: " + t.command.map(function (a) {
                        return Rules.expandPath(a, root._envFor(t));
                    }).join(" ") + "  (every " + t.intervalSeconds + "s)");

                    const p = root.lastPoll[t.id];
                    if (!p) {
                        // No poller ever started. Distinct from a poller that ran
                        // and failed, and the two used to print the same line.
                        lines.push("    poll: NEVER STARTED — no timer fired for this target");
                    } else if (!p.at) {
                        lines.push("    poll: started " + new Date(p.startedAt).toISOString() + ", nothing came back yet");
                    } else {
                        lines.push("    poll: " + new Date(p.at).toISOString() + ", " + p.bytes + " bytes, " + p.buckets + " buckets"
                            + (p.exitCode === null || p.exitCode === undefined ? "" : ", exit " + p.exitCode));
                    }
                    if (p && p.error)
                        lines.push("    poll error: " + p.error);
                    if (p && p.stderr)
                        lines.push("    stderr: " + p.stderr);
                }
            }

            for (let j = 0; j < root.invalidProviders.length; j++) {
                const bad = root.invalidProviders[j];
                lines.push("INVALID " + bad.source + ": " + bad.errors.join("; "));
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

        // Reload without restarting the shell, for when you have just edited a
        // provider file and want to know whether it parses.
        function reload(): string {
            root._rebuildTargets();
            return status();
        }

        // Re-run the directory scan itself, for when the folder model came up
        // empty or half-populated at startup. reload() only re-parses what was
        // already read; this goes back to the filesystem.
        function rescan(): string {
            root.rescan();
            return "rescanning " + root.providersDir + " — call status in a moment";
        }
    }

    Component.onCompleted: {
        // Create it rather than tolerate its absence: a missing folder is the
        // case where FolderListModel falls back to the working directory, and a
        // wrong-but-plausible scan is harder to notice than an empty one.
        Paths.mkdir(Paths.toFileUrl(providersDir));

        const saved = pluginService ? pluginService.loadPluginState(pluginId, stateKey, null) : null;
        if (saved && typeof saved.lastSeenTs === "number") {
            state = {
                lastSeenTs: saved.lastSeenTs,
                targets: saved.targets || {},
                visitsSeen: saved.visitsSeen || {}
            };
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
