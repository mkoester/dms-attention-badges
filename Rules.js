// Pure matching / parsing / state logic for attention badges.
//
// Everything here is a function of its arguments: no QML types, no side effects,
// no I/O. That is deliberate — this file is imported by the daemon, by the widget
// and by scripts/test (plain node), so the fragile part (parsing notification text)
// is unit-testable without a running shell.
//
// State shape:
//   { lastSeenTs: <ms>, targets: { <targetId>: { <bucketName>: <count> } } }

// ── The provider format ─────────────────────────────────────────────────────
//
// This plugin knows HOW to watch things and nothing about WHAT. Every watched
// app is described by a JSON file in the providers directory; nothing about
// Thunderbird, herdr or any other program appears in this file. The two presets
// shipped in providers/ are examples, not defaults — an install with no provider
// files badges nothing, which is the correct behaviour for a stranger.
//
// A target is fed either by counting notifications ("count") or by a provider
// reporting current state ("state"). The distinction is not cosmetic:
//
//   count — accumulates, needs an explicit reset, can drift. Right for mail: you
//           do not live in your mail client and messages genuinely pile up.
//   state — replaced wholesale on every poll, cannot drift, needs no reset at all.
//           Right for anything you sit inside, where window focus can never mean
//           "I dealt with that", and a counter only ever grows.

// Provider ids become state keys and settings keys, so they are constrained to
// the same shape DMS requires of plugin ids: no dashes, no dots, no spaces.
var ID_PATTERN = /^[a-z][a-zA-Z0-9]*$/;
var SOURCE_KINDS = ["notifications", "command"];
var DEFAULT_INTERVAL_SECONDS = 5;

// Expand the few variables a provider file is allowed to use. Provider files
// must never carry an absolute home path — they are meant to be copied between
// machines and users — so the expansion happens here, from an explicit env
// object, which also makes it testable without touching the real environment.
function expandPath(path, env) {
    if (typeof path !== "string" || path === "")
        return "";
    const e = env || {};
    const home = e.HOME || "";
    const vars = {
        HOME: home,
        XDG_STATE_HOME: e.XDG_STATE_HOME || (home ? home + "/.local/state" : ""),
        XDG_CONFIG_HOME: e.XDG_CONFIG_HOME || (home ? home + "/.config" : ""),
        XDG_CACHE_HOME: e.XDG_CACHE_HOME || (home ? home + "/.cache" : "")
    };
    let out = path;
    if (out.indexOf("~/") === 0)
        out = home + out.slice(1);
    Object.keys(vars).forEach(function (name) {
        out = out.split("${" + name + "}").join(vars[name]);
        out = out.split("$" + name).join(vars[name]);
    });
    return out;
}

function _isPlainObject(v) {
    return !!v && typeof v === "object" && !Array.isArray(v);
}

// Does this string compile as a regex? A bad pattern in a provider file must be
// reported at load time — left to run time it would throw inside the fold and
// take the whole badge down for every app, not just the broken one.
function _regexError(pattern) {
    try {
        new RegExp(pattern);
        return null;
    } catch (e) {
        return String(e.message || e);
    }
}

// One provider file -> { target, errors }. `target` is null when errors is
// non-empty; a partially valid provider is never returned, because a target
// missing its match criteria would silently swallow every notification.
function parseProvider(data) {
    const errors = [];
    const fail = function (msg) { errors.push(msg); };

    if (!_isPlainObject(data))
        return { target: null, errors: ["not a JSON object"] };

    const id = data.id;
    if (typeof id !== "string" || !ID_PATTERN.test(id))
        fail("id must match " + ID_PATTERN + " (got " + JSON.stringify(id) + ")");

    const source = data.source;
    if (!_isPlainObject(source)) {
        fail("missing source object");
        return { target: null, errors: errors };
    }
    if (SOURCE_KINDS.indexOf(source.kind) === -1)
        fail("source.kind must be one of " + SOURCE_KINDS.join(", ") + " (got " + JSON.stringify(source.kind) + ")");

    const target = {
        id: id,
        label: typeof data.label === "string" && data.label ? data.label : id,
        icon: typeof data.icon === "string" && data.icon ? data.icon : "notifications"
    };

    if (source.kind === "notifications") {
        // A notification source always counts: it observes arrivals, and an
        // arrival is an event, never a state.
        target.mode = "count";
        target.match = {};
        if (typeof source.desktopEntry === "string" && source.desktopEntry)
            target.match.desktopEntry = source.desktopEntry;
        if (typeof source.appName === "string" && source.appName)
            target.match.appName = source.appName;
        if (typeof source.summaryPattern === "string" && source.summaryPattern) {
            const err = _regexError(source.summaryPattern);
            if (err)
                fail("source.summaryPattern is not a valid regex: " + err);
            else
                target.match.summaryPattern = source.summaryPattern;
        }
        if (Object.keys(target.match).length === 0)
            fail("a notifications source needs at least one of desktopEntry, appName, summaryPattern");

        if (source.bucket !== undefined) {
            if (!_isPlainObject(source.bucket)) {
                fail("source.bucket must be an object");
            } else {
                const err = _regexError(source.bucket.pattern);
                if (typeof source.bucket.pattern !== "string" || err)
                    fail("source.bucket.pattern is not a valid regex: " + (err || "missing"));
                else
                    target.bucket = {
                        source: source.bucket.source === "body" ? "body" : "summary",
                        pattern: source.bucket.pattern,
                        nameGroup: source.bucket.nameGroup || 1,
                        countGroup: source.bucket.countGroup || 0
                    };
            }
        }
        target.fallbackBucket = typeof source.fallbackBucket === "string" && source.fallbackBucket
            ? source.fallbackBucket
            : "other";
    } else if (source.kind === "command") {
        target.mode = source.mode === "count" ? "count" : "state";
        if (!Array.isArray(source.command) || source.command.length === 0 ||
            !source.command.every(function (a) { return typeof a === "string"; }))
            fail("source.command must be a non-empty array of strings");
        else
            target.command = source.command.slice();
        const interval = source.intervalSeconds;
        target.intervalSeconds = typeof interval === "number" && interval >= 1
            ? interval
            : DEFAULT_INTERVAL_SECONDS;
    }

    // Resets only make sense for counters. A state target is replaced on every
    // poll, so a reset could only ever race with the next poll — and declaring
    // one is a sign the author has the two modes confused, which is worth saying
    // out loud rather than ignoring.
    const reset = data.reset;
    if (reset !== undefined) {
        if (!_isPlainObject(reset)) {
            fail("reset must be an object");
        } else if (target.mode === "state") {
            fail("a state target takes no reset — it is replaced on every poll");
        } else if (reset.kind !== "windowFocus") {
            fail('reset.kind must be "windowFocus" (got ' + JSON.stringify(reset.kind) + ")");
        } else if (typeof reset.windowClass !== "string" || !reset.windowClass) {
            fail("reset.windowClass is required, and must be read off a LIVE window");
        } else {
            target.windowClass = reset.windowClass;
            // Optional: an external helper reports which buckets you actually
            // looked at, so focus clears those rather than the whole app. The
            // file EXISTING is what switches the behaviour — see bridgeIsLive().
            if (typeof reset.perBucketFile === "string" && reset.perBucketFile)
                target.perBucketFile = reset.perBucketFile;
        }
    }

    return errors.length ? { target: null, errors: errors } : { target: target, errors: [] };
}

// Every discovered provider file -> { targets, invalid }. `invalid` is carried
// rather than dropped: a provider that fails to load must be visible in the
// settings page and in status(), because a silently skipped file looks exactly
// like an app that simply has not notified yet.
function buildTargets(files) {
    const targets = [];
    const invalid = [];
    const seen = {};

    (files || []).forEach(function (file) {
        const source = (file && file.source) || "(unknown)";
        const result = parseProvider(file && file.data);
        if (!result.target) {
            invalid.push({ source: source, errors: result.errors });
            return;
        }
        // First file wins, so a user override placed earlier in the scan cannot
        // be clobbered by a shipped preset with the same id.
        if (seen[result.target.id]) {
            invalid.push({ source: source, errors: ["duplicate id " + result.target.id + ", already defined by " + seen[result.target.id]] });
            return;
        }
        seen[result.target.id] = source;
        result.target.source = source;
        targets.push(result.target);
    });

    return { targets: targets, invalid: invalid };
}

// The stdout contract for a command provider: {"buckets": {"<name>": <count>}}.
//
// Deliberately strict, and deliberately loud. The predecessor of this function
// read a field off the wrong nesting level of a payload it had never seen, and
// succeeded on every poll while finding nothing — which is indistinguishable
// from "nothing is waiting". So every rejection here carries a reason, and the
// daemon reports what it SAW (bytes, parsed, bucket count), not just its verdict.
function parseCommandOutput(text) {
    const raw = typeof text === "string" ? text.trim() : "";
    if (raw === "")
        return { buckets: {}, error: "no output" };

    let payload;
    try {
        payload = JSON.parse(raw);
    } catch (e) {
        return { buckets: {}, error: "not JSON: " + String(e.message || e) };
    }
    if (!_isPlainObject(payload))
        return { buckets: {}, error: "top level is not an object" };
    if (!_isPlainObject(payload.buckets))
        return { buckets: {}, error: 'missing "buckets" object' };

    const buckets = {};
    let skipped = 0;
    Object.keys(payload.buckets).forEach(function (name) {
        const count = payload.buckets[name];
        if (typeof count !== "number" || !isFinite(count) || count < 1) {
            skipped++;
            return;
        }
        buckets[name] = Math.floor(count);
    });
    return {
        buckets: buckets,
        error: skipped ? skipped + " bucket(s) had a non-positive count and were dropped" : null
    };
}

// Drop state belonging to providers that no longer exist. Without this, deleting
// a provider file leaves its counts in the persisted state forever — invisible
// in the bar (nothing renders it) but still there, and back the moment a
// provider with the same id reappears.
function pruneOrphans(state, targets) {
    const live = {};
    (targets || []).forEach(function (t) { live[t.id] = true; });
    const kept = {};
    let dropped = false;
    Object.keys((state && state.targets) || {}).forEach(function (id) {
        if (live[id])
            kept[id] = state.targets[id];
        else
            dropped = true;
    });
    return dropped ? Object.assign({}, state, { targets: kept }) : state;
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
    // A state target is owned by its provider. Letting notifications also feed it
    // would double-count and reintroduce exactly the drift state mode removes.
    if (target.mode === "state")
        return false;
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
    let next = Object.assign({}, state, {
        lastSeenTs: Math.max(state.lastSeenTs || 0, ts),
        targets: Object.assign({}, state.targets)
    });

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
    return Object.assign({}, state, { targets: targets });
}

// Replace a target's buckets outright — how a state provider reports. Passing an
// empty object removes the target, so "nothing is blocked any more" needs no
// separate clear call and cannot be forgotten.
function setTargetBuckets(state, targetId, buckets) {
    const targets = Object.assign({}, state.targets);
    const names = Object.keys(buckets || {});
    if (names.length === 0)
        delete targets[targetId];
    else
        targets[targetId] = Object.assign({}, buckets);
    return Object.assign({}, state, { targets: targets });
}

// ── Per-bucket resets ───────────────────────────────────────────────────────
// A counted target may name a `reset.perBucketFile`. Some helper — for
// Thunderbird it is a MailExtension plus a native host — writes
// {version, updatedAt, visits:{<bucket>: ms}} there when you look at one bucket
// of that app. Its presence is what upgrades the reset from "focusing the window
// clears the whole app" to "clears the bucket you opened".
//
// Nothing here is Thunderbird-specific: a bucket is whatever the provider's
// regex produced, and any app that can report which of its own sections you
// visited can use the same file.

// Stale enough that the extension was probably uninstalled — fall back to focus
// clearing rather than leaving a dead file in charge of the reset forever.
var BRIDGE_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;

function bridgeIsLive(payload, nowMs) {
    if (!payload || typeof payload !== "object")
        return false;
    if (!payload.visits || typeof payload.visits !== "object")
        return false;
    const updatedAt = payload.updatedAt || 0;
    return updatedAt > 0 && (nowMs - updatedAt) < BRIDGE_MAX_AGE_MS;
}

// Clear the buckets visited since we last looked. Visits already processed are
// remembered in state.visitsSeen, so re-reading the file — which happens on
// every write, and once at startup — never re-clears a bucket that has
// legitimately counted something new since the visit.
//
// visitsSeen is keyed globally rather than per target: a bucket name is unique
// enough in practice, and a per-target map would have to be migrated the first
// time somebody renames a provider.
function applyVisits(state, targetId, payload) {
    const visits = (payload && payload.visits) || {};
    const seen = Object.assign({}, state.visitsSeen || {});
    let buckets = Object.assign({}, (state.targets || {})[targetId] || {});
    let changed = false;

    Object.keys(visits).forEach(function (address) {
        const at = visits[address] || 0;
        if ((seen[address] || 0) >= at)
            return;
        seen[address] = at;
        Object.keys(buckets).forEach(function (name) {
            if (name.toLowerCase() === address.toLowerCase()) {
                delete buckets[name];
                changed = true;
            }
        });
    });

    const next = changed ? setTargetBuckets(state, targetId, buckets) : state;
    return Object.assign({}, next, { visitsSeen: seen });
}

function clearBucket(state, targetId, bucketName) {
    const buckets = Object.assign({}, state.targets[targetId] || {});
    delete buckets[bucketName];
    const targets = Object.assign({}, state.targets);
    if (Object.keys(buckets).length === 0)
        delete targets[targetId];
    else
        targets[targetId] = buckets;
    return Object.assign({}, state, { targets: targets });
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
        expandPath: expandPath,
        parseProvider: parseProvider,
        buildTargets: buildTargets,
        parseCommandOutput: parseCommandOutput,
        pruneOrphans: pruneOrphans,
        emptyState: emptyState,
        matches: matches,
        parse: parse,
        applyEntry: applyEntry,
        applyHistory: applyHistory,
        setTargetBuckets: setTargetBuckets,
        bridgeIsLive: bridgeIsLive,
        applyVisits: applyVisits,
        clearTarget: clearTarget,
        clearBucket: clearBucket,
        totalFor: totalFor,
        bucketList: bucketList,
        targetForWindowClass: targetForWindowClass
    };
}
