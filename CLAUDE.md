# dms-attention-badges — session hand-off

A DankMaterialShell (Quickshell/QML) plugin. **User-facing docs are in `README.md`** —
what the plugin does, how to install it, its known limits and the provider roadmap. This
file holds what the next session needs and the README should not carry: the DMS plugin API
as *measured*, and the traps found while writing it.

Everything below was read out of the shipped shell at `/usr/share/quickshell/dms`
(`dms-shell 1.5.3-1`, `quickshell 0.3.0-2.1`) — that tree is the primary source and beats
both memory and the online docs. `PLUGINS/` in it ships worked examples, a
`plugin-schema.json` and a theme reference.

## Plugin API, verified

| Thing | Fact |
|---|---|
| manifest `id` | must match `^[a-zA-Z][a-zA-Z0-9]*$` — **camelCase, no dashes**, so the id (`attentionBadges`) can never equal the repo name |
| surfaces | `components: { widget, desktop, daemon, launcher }` with `type: "composite"`; each loads independently, a daemon is instantiated once |
| plugin dir | `~/.config/DankMaterialShell/plugins/<id>` — a symlink works |
| settings | `pluginData` on `PluginComponent` (read); `PluginSettings` + `saveValue()` in the settings component (write). Empty `{}` until saved once, so **defaults must be expressed as `!== false`**, not `|| true` |
| state | `pluginService.savePluginState/loadPluginState(pluginId, key, value)` → debounced write to `~/.local/state/DankMaterialShell/plugins/<id>_state.json`. Separate from settings; this is the right home for daemon state |
| cross-surface comms | `PluginService.pluginStateChanged(pluginId)`. Daemon and widget are **separate instances** and cannot call each other — one writer, everyone else listens |
| IPC | `IpcHandler { target: "<name>" }` with typed functions, reachable as `dms ipc call <target> <function> [args]` |
| bar rendering | set `horizontalBarPill` / `verticalBarPill` / `popoutContent` Components on `PluginComponent`; `BasePill` handles background, ripple, blur and click routing |
| widget picker | plugin widgets are appended to the core list in `Modules/Settings/WidgetsTab.qml:279`; a disabled plugin shows greyed out |

`import qs.Services` works from a plugin, so `NotificationService`, `CompositorService`,
`ToastService` and the rest of the shell's singletons are directly available.

## Traps

- **There is no working QML checker.** `qmllint` and `qmlformat` from qt6-declarative 6.11
  exit non-zero on *shipped, working* DMS files that use `?.`/`??` (verified against
  `Services/ClipboardService.qml`). Do not add one and do not trust one.
  - The first attempt at a gate was worse than none: `qmllint --bare` is not a valid
    option in this version, so every file printed `Unknown option 'bare'`, a grep for
    `Error` counted zero, and three files "passed". **A tool that rejected the invocation
    reads exactly like a tool that found nothing.** Check the exit code, and run a
    deliberately broken file as a control before believing any gate.
- **`Rules.js` is plain JS on purpose** — no `.pragma library`, and a guarded
  `module.exports` tail so `scripts/test` can `require()` it under node. That is the only
  automated coverage this repo has; keep logic out of the QML so it stays that way.
- **Window classes come from a live window**, `hyprctl -j clients | grep -i class`, never
  from a `.desktop` file. Thunderbird advertises `StartupWMClass=thunderbird` and actually
  maps as `org.mozilla.Thunderbird`; the notification's `desktopEntry` happens to equal the
  window class for it, which is what makes the notification↔focus join work with no
  mapping table. Not universally true — Brave notifies as `brave-browser`.
- **First run must seed `lastSeenTs = Date.now()`.** Folding the stored history instead
  would greet a fresh install with a badge counting the last 7 days of notifications.
- **Notification history is capped and prunable** (`notificationHistoryMaxCount` 50,
  `MaxAgeDays` 7, and it can be disabled). It is the *arrival hook* only — the counts are
  ours and are persisted separately, deliberately.

## Why herdr is a state target, not a counter (2026-08-11)

The first version counted herdr from its notifications and **the number only ever grew** —
correctly, and uselessly. The reset fires on `activeToplevelChanged`, and you are normally
*already focused on herdr* when an agent blocks, so no focus change ever happens. Clearing
on arrival instead would have pinned it at zero. **Window focus cannot express "I dealt
with that pane"** for an app you live inside; that is a granularity limit, not a bug, and
no amount of tuning the counter fixes it.

The fix was to change the model. `mode: "state"` targets are *replaced* on every provider
poll rather than accumulated, so they cannot drift and need no reset: a pane leaves the
badge when its agent stops being blocked. `matches()` returns false for state targets so
the notification stream cannot double-feed them.

**`herdr api schema --json` works with no running server** — it is bundled in the binary —
so `SessionSnapshot`, `AgentInfo` and the `AgentStatus` enum
(`idle`/`working`/`blocked`/`done`/`unknown`) are measured, not guessed. Use it before
touching anything herdr-shaped; `herdr agent list` and `herdr api snapshot` both need the
socket and are therefore blocked in the sandbox.

**But the schema describes the payload, NOT the CLI's framing — and that cost a full
round of testing (2026-08-11).** `herdr api snapshot` prints the socket *response
envelope*: `{"id":"cli:api:snapshot","result":{"snapshot":{ … }}}`. Reading `.agents` off
the top level therefore succeeded at every step — the command ran, the JSON parsed, no
error was raised anywhere — and simply found zero agents forever. The badge sat at 0,
which is also what "nothing is waiting" looks like, so three polls' worth of evidence said
nothing. **A schema is authoritative for the shape of a message and says nothing about how
a CLI wraps it**; capture one real line of output before writing a parser, and when a
value cannot be captured, make the code report what it *did* see (`herdr poll: … bytes,
parsed=…, agents=…`, plus a histogram of the statuses) rather than only its verdict. That
diagnostic named the cause in one command after three rounds of ranked guessing.

## The Thunderbird bridge is a RESET provider, not a full one

Originally scoped as "the extension owns per-account counts and resets". It shipped much
smaller: the notification counts were already accurate, so duplicating them in the
extension would have created a second source of truth for the same number. The extension
sends **only the thing the desktop cannot see** — which account you opened.

Consequences to keep in mind when changing either side:

- `state.visitsSeen` is the plugin's memory of which visits it already acted on. **Every
  state helper must preserve keys it does not own** (they use `Object.assign({}, state, …)`
  for this) — an earlier version rebuilt the state object from `{lastSeenTs, targets}` and
  would have silently dropped `visitsSeen` on the next notification, making each file read
  look new and re-clearing a bucket that had just counted mail.
- **The file existing is the switch**, not a setting. No file ⇒ the old focus-clears-
  everything behaviour, which is what makes the bridge safe to uninstall. Older than 7 days
  ⇒ treated as abandoned.
- The bridge reports **every identity of the visited account**, because mail arrives at
  aliases and buckets are keyed by whatever address the notification named.

## TODO

**1. Fleet install — the repo has to move to `~/src` first (2026-08-12).** The shared DMS
baseline (`workstation-private/shared/dms/base.json`) now lists `attentionBadges` in the bar,
so every machine expects the plugin, but it only exists inside `workspace_extensions` on
`mkDell`. Installing it fleet-wide needs a **fixed path that does not depend on a workspace
being cloned**, which is exactly the vault's rule: *"a repo whose deployment needs a clone at
a fixed path outside the workspace is outside-tree, not nested — and gets no second clone"*
([ai-workspaces](../../okf/practices/ai-workspaces.md#adding-a-member-to-an-existing-workspace)).
So: move to `~/src/dms-attention-badges`, reference it from `workspace_extensions` via
`.code-workspace` + `additionalDirectories` exactly as `dotfiles` is, and have `install.sh`
clone it and symlink it into `~/.config/DankMaterialShell/plugins/attentionBadges` under
`DF_DMS`. **Not done — MK to confirm the move.**

**2. Publishing to the DMS registry — possible, and the path is concrete.** The registry is a
git repo, `github.com/AvengeMedia/dms-plugin-registry` (85 stars, active), not a web form:
fork it, add `plugins/mkoester-attention-badges.json` naming this repo, open a PR. Its
`CONTRIBUTING.md` requires `id` and `name` to match `plugin.json` exactly — `attentionBadges`
and `Attention Badges` already satisfy the id rules (camelCase, letters only). `dms plugins
install` then clones the repo named in that entry, and the API is `api.danklinux.com/plugins`.

**3. De-personalise before publishing (agreed 2026-08-12).** The plugin currently ships MK's
setup as its built-in defaults. What has to change, concretely:

- **`Rules.js: defaultTargets()` is the whole problem.** It hardcodes two targets, one of
  which names a window class invented on this machine (`mk.herdr`, which exists only because
  a ghostty launcher was given that `--class`), and the other a regex over Thunderbird's
  English notification text. Targets must become **user configuration**; these two become
  *presets* a user can add, not defaults that fire on install.
- **A window class cannot ship as a default at all** — it is only knowable from a live
  window (`hyprctl -j clients`), varies per machine and per launcher, and a wrong one fails
  silently. It has to be a field the user fills in, ideally with a "pick from running
  windows" affordance.
- **The daemon hardcodes `"thunderbird"`** in two places — the bridge's `applyVisits` call
  and the focus-clear exemption. Both should key off a target *property* (`resetProvider`)
  rather than an id.
- **The settings UI is two named toggles.** It needs a list editor; DMS ships
  `ListSetting.qml` / `ListSettingWithInput.qml` / `SelectionSetting.qml` / `StringSetting`
  in `Modules/Plugins/`, so the components exist and this is assembly, not invention.
- **Strings are hardcoded English.** DMS uses `I18n.tr(...)` throughout; a published plugin
  should too.
- **herdr becomes an optional provider**, declared in `plugin.json` `dependencies` and
  inert when the binary is absent — right now the poll simply fails every tick and clears.
- The registry entry additionally wants `category`, `compositors` and a **screenshot**, so
  one is needed of the bar with a couple of live badges.

The shape to aim for: the plugin ships knowing *how* to watch things (notifications, a herdr
poll, a bridge file) and **nothing about what**. Same de-personalising pass Bookmarks-plus
and `thunderbird_send_as` went through before release. MK's own targets then live in his
plugin settings like anyone else's — which is also the honest test that the configuration is
actually sufficient.

Also required, and separate: **the repo must be public** (it is private), since the registry
entry is a public GitHub URL that `dms plugins install` clones.

## Unverified / open

- Whether **do-not-disturb** suppresses entries from reaching `historyList`. If it does, a
  DND window is invisible to the counter.
- Whether Thunderbird's **calendar reminders** use the same app id and a third summary
  shape. None appeared in the 50-entry sample.
- ~~The widget has never been observed rendering~~ — **confirmed working 2026-08-11.**
  Both halves of the plugin are now verified end to end on `mkDell`: Thunderbird counting
  per account and clearing on focus, herdr badging `●`/`✓` and clearing itself, and the bar
  widget rendering both.
- ~~Whether `done` is observable long enough to badge~~ — **settled 2026-08-11, it is.**
  A finishing run showed `idle=2 done=1` with a `✓` bucket while the pane was unfocused,
  and returned to `idle=3` with an empty badge once opened. So `done` persists until you
  look, and viewing is what ends it. The earlier "probably too short-lived" reading came
  from a single snapshot taken *after* the pane had already been viewed — an absence
  measured at the one moment it was guaranteed to be absent.
- **The `mk.herdr` window class is still unconfirmed** on a live window. It no longer
  affects herdr (a state target needs no focus reset) but it is the model for how
  Thunderbird's reset works, and `status()` now prints the focused class so it is one call
  to check.
