# Attention Badges — a DankMaterialShell plugin

Per-app badges in the DMS bar showing **what happened since you last focused that app**:
new mail per Thunderbird account, agents waiting in herdr. Focus the app's window and
its badge clears.

Not an unread counter. A mailbox with 4000 unread messages shows nothing until something
new arrives.

## How it works

Two inputs, both already present in DMS:

| Input | Source |
|---|---|
| what happened | `NotificationService.historyList` — every entry carries `appName`, `desktopEntry`, `summary`, `body`, `timestamp` |
| when you looked | `ToplevelManager.activeToplevel.appId` — the focused window's class |

The **daemon** surface folds new notifications into a per-app, per-bucket count and clears
a target when its window class gains focus. It runs whether or not the bar widget is
placed, so counting never depends on the widget being visible. State is persisted through
`PluginService.savePluginState`, so a shell restart does not silently zero the badges.

The **widget** surface only renders. The daemon is the single writer, so two monitors
showing the widget cannot disagree.

### Buckets

A target can split its count by a regex over the notification text:

- **Thunderbird** emits `mk@example.de received 2 new messages` — so the account is the
  bucket and the count comes from the message itself. It batches a poll into one
  notification and tells you how many mails it stands for, so the badge counts *mails*,
  not popups.
- **herdr** does not count at all — see below.

### Counting vs. state

Two kinds of target, and the difference is load-bearing:

| mode | behaviour | right for |
|---|---|---|
| `count` | accumulates notifications, cleared by focusing the window | Thunderbird |
| `state` | replaced wholesale on every poll of a provider, no reset at all | herdr |

Counting is wrong for an app you **sit inside**. If you are already focused on herdr when
an agent blocks, no focus change ever happens, so a counter only grows; clearing on arrival
instead would pin it at zero. Window focus simply cannot express *"I dealt with that pane"*.

So herdr is polled from its own API (`herdr api snapshot`) and the badge is the **current
set of panes whose agent wants you**, minus the pane you are focused on. It cannot drift,
because nothing accumulates: a pane leaves the badge when its agent stops waiting.

Two of the five statuses count, and they are marked apart because they are different jobs:

| status | means | mark |
|---|---|---|
| `blocked` | waiting for your input | `●` |
| `done` | finished, waiting for your review | `✓` |

`idle`, `working` and `unknown` never badge. Finished agents can be excluded with the
**Badge finished agents too** toggle.

The status vocabulary (`idle` / `working` / `blocked` / `done` / `unknown`) and every field
name come from `herdr api schema --json`, which is bundled in the binary and prints without
a running server. Note the agent-detection scripts embedded in herdr only know
`working`/`blocked`/`idle`, so `done` is derived by herdr itself — and it appears to leave
that state once you look at the pane, which is exactly what a state badge wants.

Anything a **counted** app notifies about that does not parse lands in a **fallback bucket**
(`other`) rather than being dropped. That is deliberate: the parse is a locale-dependent
string match, and a broken parse should look like a visible `other: 4`, not like silence.

## Install

```sh
mkdir -p ~/.config/DankMaterialShell/plugins
```

```sh
ln -s "$PWD" ~/.config/DankMaterialShell/plugins/attentionBadges
```

The directory does not exist on a machine that has never installed a plugin, and DMS
points its directory watcher at it *at startup* — so if `dms plugins list` does not show
the plugin after creating it, `dms restart`.

Then enable it in Settings → Plugins, and add the widget in **Settings → DankBar →
Widgets** (Left / Center / Right section). A plugin whose widget is greyed out there with
*"Plugin is disabled"* is not enabled yet.

## Verify

The badge is otherwise only observable by waiting for mail, so the daemon exposes IPC:

```sh
dms ipc call attentionBadges status
```

```sh
dms ipc call attentionBadges clear
```

```sh
dms ipc call attentionBadges clearOne thunderbird
```

Right-clicking the widget also clears everything (it calls the same IPC, so there stays
one writer).

The window classes the reset depends on must be read off a **live window**, never from a
`.desktop` file — `StartupWMClass` is a prediction and is wrong for Thunderbird:

```sh
hyprctl -j clients | grep -i class
```

## Tests

```sh
./scripts/test
```

Covers `Rules.js` — matching, parsing, folding history, resets. The fixtures are
shape-faithful copies of real entries from
`~/.cache/DankMaterialShell/notification_history.json` (addresses replaced), because a
tidy invented fixture would pass whatever the regex happens to do.

**The QML is not covered by any automated check.** `qmllint`/`qmlformat` from
`qt6-declarative` 6.11 cannot parse this codebase at all — they exit non-zero on shipped,
working DMS files that use `?.`/`??` (verified against
`Services/ClipboardService.qml`), so a green run would prove nothing. The QML is validated
only by loading it in a running shell.

## Known limits

- **The Thunderbird parse is a localized UI string.** A locale change breaks it silently
  except for everything landing in `other`.
- **Focus resets a whole app.** Hyprland reports that Thunderbird got focus, not which
  account you looked at. Per-account clearing needs
  [thunderbird-attention-bridge](https://github.com/mkoester/thunderbird-attention-bridge),
  which reports folder navigation from inside Thunderbird.
- **The herdr provider polls; it does not subscribe.** herdr's socket API has an event
  stream (`events.subscribe` → `pane.agent_status_changed`) which would be lower-latency,
  but a poll is stateless and self-healing: a herdr restart, a dropped connection or a
  missed event all recover on the next tick rather than freezing the badge silently. The
  cost is up to `herdrPollSeconds` (default 3) of lag and one process spawn per tick.
- **If `herdr api snapshot` fails, the herdr badge clears** rather than holding stale
  entries. herdr not running does mean nothing is waiting; a transient failure blanks it
  for one tick.
- **`herdr api snapshot` prints the socket response envelope**, not a bare snapshot:
  `{"id":…,"result":{"snapshot":{…}}}`. Both forms are accepted. This is the one thing the
  bundled schema could not tell us, and getting it wrong produced a parser that succeeded
  on every poll and found zero agents forever.
- **`done` clears when you view the pane** — confirmed 2026-08-11 by watching the status
  histogram across a finishing run: `idle=2 done=1` with a `✓` bucket while away, back to
  `idle=3` and an empty badge once the pane was opened. That is herdr's own behaviour, not
  anything this plugin does, and it is why the review queue needs no acknowledgement step.
- **Do-not-disturb is untested**: whether suppressed notifications still reach the history
  is unverified, and if they do not, a DND window is invisible to the counter.

## Roadmap

The two inputs above are one **provider**. The model is provider-agnostic on purpose:

| Provider | Source | Buckets | Reset |
|---|---|---|---|
| `notifications` (done) | DMS notification history | regex over summary/body | window focus |
| `herdr` (done) | `herdr api snapshot` poll | pane | none needed — it is state |
| `thunderbird` | native host ← Thunderbird extension | account | folder navigation |
