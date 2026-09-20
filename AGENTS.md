# dms-attention-badges

A DankMaterialShell (Quickshell) plugin — daemon + bar widget — showing per-app badges for *what
happened since you last focused that app*. Deliberately **not** an unread counter.

**It is a host, not a bundle of features.** Every watched app is a JSON provider file in
`~/.config/DankMaterialShell/attention-providers/`; nothing in the plugin names Thunderbird or
herdr, which ship as examples in `providers/`. `README.md` documents the provider format.

Cross-project conventions come from the OKF vault; workspace rules from `../AGENTS.md`. The
reasoning, the why-not-a-tray-app analysis and the TODO list are in `docs/design-notes.md`.

## The distinction that is load-bearing

**`count` accumulates and is cleared by window focus** (mail). **`state` is replaced on every poll
and needs no reset** (herdr). Window focus cannot mean *"I dealt with that"* for an app you sit
inside, where a counter only ever grows. A `command` provider prints its own `{"buckets": …}`,
which is what keeps app-specific extraction out of the core.

## Plugin API, verified

| Thing | Fact |
|---|---|
| manifest `id` | must match `^[a-zA-Z][a-zA-Z0-9]*$` — camelCase, no dashes, so the id can never equal the repo name |
| surfaces | `components: { widget, desktop, daemon, launcher }`, `type: "composite"`; each loads independently, a daemon is instantiated once |
| plugin dir | `~/.config/DankMaterialShell/plugins/<id>` — a symlink works |
| settings | `pluginData` on `PluginComponent` (read); `PluginSettings` + `saveValue()` (write). Empty `{}` until saved once, so **defaults must be `!== false`, never `\|\| true`** |
| state | `pluginService.savePluginState/loadPluginState(pluginId, key, value)`, debounced to `~/.local/state/.../<id>_state.json`. Separate from settings; the right home for daemon state |
| cross-surface comms | `PluginService.pluginStateChanged(pluginId)`. Daemon and widget are **separate instances and cannot call each other** — one writer, everyone else listens |
| IPC | `IpcHandler { target: "<name>" }`, reachable as `dms ipc call <target> <fn> [args]` |
| bar rendering | set `horizontalBarPill` / `verticalBarPill` / `popoutContent`; `BasePill` handles background, ripple, blur and click routing |
| cross-plugin state | `PluginService` has **no access control** — any plugin can read or write any other's state. A reason not to treat plugin state as private |
| directory scanning | `Qt.labs.folderlistmodel` works (ships in `qt6-declarative`, which DMS itself uses) |
| dynamic children | `Instantiator` over a model with `FileView`/`Timer` delegates carrying `required property var modelData` |
| settings page | `PluginSettings` reparents `Item` children into its column, so a `Repeater` works as a child |
| ⚠ settings timing | `pluginService` is assigned **after** construction — `Component.onCompleted` alone reads `null`. Handle `onPluginServiceChanged` too, or the page stays permanently empty |

`import qs.Services` works from a plugin, so `NotificationService`, `CompositorService` and the
shell's other singletons are directly available.

## ⚠ Traps

- **There is no working QML checker.** `qmllint`/`qmlformat` from qt6-declarative 6.11 exit
  non-zero on *shipped, working* DMS files using `?.`/`??`. Do not add a gate and do not trust one,
  except the one narrow syntax-only smoke test described in `docs/design-notes.md`.
  - The first attempt was worse than none: `qmllint --bare` is not a valid option, so every file
    printed `Unknown option 'bare'`, a grep for `Error` counted zero, and three files "passed".
    **A tool that rejected the invocation reads exactly like a tool that found nothing.** Check the
    exit code, and run a deliberately broken file as a control before believing any gate.
- **`parseProvider` returns `{target, errors}` — a plural array, not `error`.** A test written as
  `parsed.error || ""` compares `undefined` to `""`, passes for *every* input, and reads as a green
  validation check; a deliberately invalid provider sailed through it. Assert `target === null` on
  failure too.
- **`Rules.js` is plain JS on purpose** — no `.pragma library`, with a guarded `module.exports`
  tail so `scripts/test` can `require()` it under node. **That is the only automated coverage this
  repo has; keep logic out of the QML so it stays that way.**
- **Window classes come from a live window** (`hyprctl -j clients`), never from a `.desktop` file.
  Thunderbird advertises `StartupWMClass=thunderbird` but maps as `org.mozilla.Thunderbird`.
- **First run must seed `lastSeenTs = Date.now()`**, not fold the stored history.
- The systemd user unit does **not** inherit an interactive `PATH`, and
  `StandardPaths.writableLocation` returns a URL that needs its prefix stripped.
