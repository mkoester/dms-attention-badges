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
- **herdr** shells out to plain `notify-send` with no `--app-name`, so it has no app
  identity of its own — it is matched on the summary (`… needs attention`) and bucketed by
  the body (`<workspace> · <pane> · <program>`).

Anything a watched app notifies about that does not parse lands in a **fallback bucket**
(`other`) rather than being dropped. That is deliberate: the parse is a locale-dependent
string match, and a broken parse should look like a visible `other: 4`, not like silence.

## Install

```sh
ln -s "$PWD" ~/.config/DankMaterialShell/plugins/attentionBadges
```

Then enable it in DMS Settings → Plugins, and add the widget to a bar section.

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
- **herdr is matched by notification text**, which is fragile — herdr has a proper event
  API (`pane.agent_status_changed` over `~/.config/herdr/herdr.sock`) that should replace
  this. See the roadmap.
- **Do-not-disturb is untested**: whether suppressed notifications still reach the history
  is unverified, and if they do not, a DND window is invisible to the counter.

## Roadmap

The two inputs above are one **provider**. The model is provider-agnostic on purpose:

| Provider | Source | Buckets | Reset |
|---|---|---|---|
| `notifications` (done) | DMS notification history | regex over summary/body | window focus |
| `thunderbird` | native host ← Thunderbird extension | account | folder navigation |
| `herdr` | `herdr.sock` event subscription | pane | `pane.focused` |
