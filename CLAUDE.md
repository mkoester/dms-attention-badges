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

## Unverified / open

- Whether **do-not-disturb** suppresses entries from reaching `historyList`. If it does, a
  DND window is invisible to the counter.
- Whether Thunderbird's **calendar reminders** use the same app id and a third summary
  shape. None appeared in the 50-entry sample.
- The **widget** has never been observed rendering — as of the first session it was loaded
  and the daemon was confirmed counting via IPC, but the bar half is untested.
