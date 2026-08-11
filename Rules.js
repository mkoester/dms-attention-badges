// Pure matching / parsing / state logic for attention badges.
//
// Everything here is a function of its arguments: no QML types, no side effects,
// no I/O. That is deliberate — this file is imported by the daemon, by the widget
// and by scripts/test (plain node), so the fragile part (parsing notification text)
// is unit-testable without a running shell.
//
// State shape:
//   { lastSeenTs: <ms>, targets: { <targetId>: { <bucketName>: <count> } } }

function defaultTargets() {
    return [
        {
            id: "thunderbird",
            label: "Thunderbird",
            icon: "mail",
            // Read off a live window (hyprctl -j clients), NOT from the .desktop file:
            // Thunderbird advertises StartupWMClass=thunderbird and maps as this.
            windowClass: "org.mozilla.Thunderbird",
            match: { desktopEntry: "org.mozilla.Thunderbird" },
            // "mk@example.de received 2 new messages" -> bucket "mk@example.de", count 2
            bucket: {
                source: "summary",
                pattern: "^(\\S+@\\S+) received (\\d+) new messages?$",
                nameGroup: 1,
                countGroup: 2
            },
            // Anything Thunderbird notifies about that is not new mail (connection
            // failures, calendar reminders) lands here rather than being dropped.
            fallbackBucket: "other"
        },
        {
            id: "herdr",
            label: "herdr",
            icon: "terminal",
            windowClass: "mk.herdr",
            // herdr shells out to plain notify-send with no --app-name, so it has no
            // app identity of its own; the summary is the only thing that marks it.
            match: { appName: "notify-send", summaryPattern: " needs attention$" },
            // body is "<workspace> · <pane> · <program>"
            bucket: { source: "body", pattern: "^(.+)$", nameGroup: 1 },
            fallbackBucket: "agent"
        }
    ];
}

function emptyState() {
    return { lastSeenTs: 0, targets: {} };
}

function _field(entry, name) {
    const v = entry ? entry[name] : "";
    return typeof v === "string" ? v : "";
}

// Does this notification belong to this target?
function matches(target, entry) {
    const m = target.match || {};
    if (m.desktopEntry && _field(entry, "desktopEntry") !== m.desktopEntry)
        return false;
    if (m.appName && _field(entry, "appName") !== m.appName)
        return false;
    if (m.summaryPattern && !new RegExp(m.summaryPattern).test(_field(entry, "summary")))
        return false;
    // A target with no criteria at all would swallow every notification.
    return !!(m.desktopEntry || m.appName || m.summaryPattern);
}

// Which bucket does it go in, and by how much?
function parse(target, entry) {
    const spec = target.bucket;
    const fallback = { bucket: target.fallbackBucket || "other", count: 1 };
    if (!spec)
        return fallback;

    const text = _field(entry, spec.source || "summary").trim();
    const hit = new RegExp(spec.pattern).exec(text);
    if (!hit)
        return fallback;

    const name = (hit[spec.nameGroup || 1] || "").trim();
    if (!name)
        return fallback;

    let count = 1;
    if (spec.countGroup) {
        const parsed = parseInt(hit[spec.countGroup], 10);
        // A matched-but-unparseable count is worth 1, never 0 — dropping it would
        // hide the event entirely.
        count = isNaN(parsed) || parsed < 1 ? 1 : parsed;
    }
    return { bucket: name, count: count };
}

// Fold one notification into the state. Returns a new state; never mutates input.
function applyEntry(state, targets, entry) {
    const ts = typeof entry.timestamp === "number" ? entry.timestamp : 0;
    let next = {
        lastSeenTs: Math.max(state.lastSeenTs || 0, ts),
        targets: Object.assign({}, state.targets)
    };

    for (let i = 0; i < targets.length; i++) {
        const target = targets[i];
        if (!matches(target, entry))
            continue;
        const hit = parse(target, entry);
        const buckets = Object.assign({}, next.targets[target.id] || {});
        buckets[hit.bucket] = (buckets[hit.bucket] || 0) + hit.count;
        next.targets[target.id] = buckets;
        // First match wins: a notification belongs to one app.
        break;
    }
    return next;
}

// Fold every history entry newer than state.lastSeenTs, oldest first.
// DMS stores history newest-first, hence the sort.
function applyHistory(state, targets, history) {
    const fresh = (history || [])
        .filter(function (e) { return (e.timestamp || 0) > (state.lastSeenTs || 0); })
        .sort(function (a, b) { return (a.timestamp || 0) - (b.timestamp || 0); });

    let next = state;
    for (let i = 0; i < fresh.length; i++)
        next = applyEntry(next, targets, fresh[i]);
    return next;
}

// Clear one target's buckets — what happens when you focus its window.
function clearTarget(state, targetId) {
    const targets = Object.assign({}, state.targets);
    delete targets[targetId];
    return { lastSeenTs: state.lastSeenTs, targets: targets };
}

function clearBucket(state, targetId, bucketName) {
    const buckets = Object.assign({}, state.targets[targetId] || {});
    delete buckets[bucketName];
    const targets = Object.assign({}, state.targets);
    if (Object.keys(buckets).length === 0)
        delete targets[targetId];
    else
        targets[targetId] = buckets;
    return { lastSeenTs: state.lastSeenTs, targets: targets };
}

function totalFor(state, targetId) {
    const buckets = (state.targets || {})[targetId] || {};
    return Object.keys(buckets).reduce(function (sum, k) { return sum + buckets[k]; }, 0);
}

// [{ name, count }], biggest first — what the popout lists.
function bucketList(state, targetId) {
    const buckets = (state.targets || {})[targetId] || {};
    return Object.keys(buckets)
        .map(function (k) { return { name: k, count: buckets[k] }; })
        .sort(function (a, b) { return b.count - a.count || a.name.localeCompare(b.name); });
}

// Which target owns this window class, if any? Used for the focus reset.
function targetForWindowClass(targets, appId) {
    if (!appId)
        return null;
    const lower = appId.toLowerCase();
    for (let i = 0; i < targets.length; i++) {
        if ((targets[i].windowClass || "").toLowerCase() === lower)
            return targets[i];
    }
    return null;
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        defaultTargets: defaultTargets,
        emptyState: emptyState,
        matches: matches,
        parse: parse,
        applyEntry: applyEntry,
        applyHistory: applyHistory,
        clearTarget: clearTarget,
        clearBucket: clearBucket,
        totalFor: totalFor,
        bucketList: bucketList,
        targetForWindowClass: targetForWindowClass
    };
}
