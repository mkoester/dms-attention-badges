# What to watch

A fresh install badges nothing, on purpose — so the first question is always *what should I
point this at?* This is the catalogue, and more usefully the test for deciding whether
something belongs here at all.

`README.md` is the format reference. Nothing below is shipped; each is a file you write.

## The fit test

Ask these in order. The first *yes* decides it.

| | Answer | Then |
|---|---|---|
| 1 | Is the number you want **unread**, or anything else that is already true before today? | **Not this plugin.** A badge that is never empty is wallpaper — see [Anti-patterns](#anti-patterns). |
| 2 | Does *dealing with it* mean **focusing that app's window**? | `notifications`, mode `count`. The window focus is the reset. |
| 3 | Can **one command** answer *"what is waiting right now"* in under a second? | `command`, mode `state`. It replaces itself every poll and needs no reset. |
| 4 | Neither — it is an event, and the thing it comes from has no window | It fits awkwardly today; see [What the format cannot do yet](#what-the-format-cannot-do-yet). |

Question 2 is the one people get wrong. Focusing Firefox does not mean you dealt with the
review queue you happen to read in Firefox, so anything you handle *in a browser* is a
question-3 provider, not a question-2 one.

## Things that already notify → `notifications`

You get these almost free: the app is emitting the events, DMS is already recording them, and
a provider is a few lines of matching.

**Chat, bucketed by who is waiting.** Signal, Element/Matrix, Telegram, Discord — all notify
with the sender or room in the summary, which is exactly a bucket:

```json
{
    "id": "signal",
    "label": "Signal",
    "icon": "chat",
    "source": {
        "kind": "notifications",
        "desktopEntry": "signal",
        "bucket": { "source": "summary", "pattern": "^(.+)$", "nameGroup": 1 },
        "fallbackBucket": "other"
    },
    "reset": { "kind": "windowFocus", "windowClass": "signal" }
}
```

These apps do have tray icons, so the honest question is what this adds. The same thing it
adds for mail: a tray badge counts **unread**, which for a chat client with thirty muted rooms
is a number you have trained yourself to ignore. This counts **since you last looked**, which
goes back to zero when you look. Read `desktopEntry` and `windowClass` off your own machine
before writing either down — both are guesses otherwise, and a wrong one fails silently.

**ntfy, bucketed by topic.** A self-hosted push topic per concern (backups, CI, doorbell) maps
onto buckets exactly, with no parsing beyond pulling the topic out of the summary.

**Your own scripts.** Anything can put itself on the bar in one line, with no provider code at
all beyond a `desktopEntry` you invent:

```sh
notify-send --hint=string:desktop-entry:my.jobs "borg: 2 repos failed" "see journalctl -u borg"
```

Point a provider's `desktopEntry` at `my.jobs` and every script you own shares one badge. The
catch is the reset: an invented desktop entry has no window, so nothing ever clears it. Either
name the `windowClass` of the terminal you would go and fix it in, or clear it deliberately
with `dms ipc call attentionBadges clearOne my.jobs`, or — usually better — make it a `state`
provider that reports the current failures instead of counting past ones.

## Queues you deal with somewhere else → `command`

Self-hosted things with a web UI have no desktop presence at all, and a poll against their API
is the whole provider. The shape is always the same: fetch, count, print buckets.

Worth badging: **Paperless-ngx** documents in the inbox, **Vikunja** tasks due or overdue,
**linkding** bookmarks not yet processed, **GitLab** merge requests awaiting your review,
**GitHub** notifications (`gh api notifications`), **Transmission** torrents finished and
waiting to be filed, **Home Assistant** persistent notifications and unavailable entities.

Give network polls a long `intervalSeconds` — 60 to 300. Every tick is a process spawn and a
round trip, and none of these change per second. Compare the herdr provider's 3 s, which is
local and answers instantly.

Past one line, put a script beside `provider.json` and call it through `$PROVIDER_DIR`, the
way the herdr provider does. That is what makes a provider a self-contained `git clone`.

## Machine health that is silent until it bites → `command`

This is where a badge earns the most, because for most of these **nothing notifies you at
all** today. They are also the best possible fit for `state`: each is a question with a
current answer, and each is empty almost always — so the badge appearing *is* the signal.

Two that were run against this machine, both branches, and print exactly the contract:

```json
{
    "id": "pacnew",
    "label": "Config conflicts",
    "icon": "rule_folder",
    "source": {
        "kind": "command",
        "command": ["sh", "-c", "find /etc -name '*.pacnew' -printf '%f\\n' | jq -Rsc '{buckets: (split(\"\\n\") | map(select(length>0)) | map({(.):1}) | add // {})}'"],
        "intervalSeconds": 900,
        "mode": "state"
    }
}
```

```json
{
    "id": "rebootNeeded",
    "label": "Reboot",
    "icon": "restart_alt",
    "source": {
        "kind": "command",
        "command": ["sh", "-c", "[ -d \"/usr/lib/modules/$(uname -r)\" ] && echo '{\"buckets\":{}}' || echo '{\"buckets\":{\"kernel upgraded\":1}}'"],
        "intervalSeconds": 900,
        "mode": "state"
    }
}
```

The kernel one is worth explaining, because the obvious version is wrong: comparing `uname -r`
to the installed package version fails on a normal machine, since the running kernel prints
`7.1.8-1-cachyos` where the package says `7.1.8-1`. What actually holds is that the module
directory for the running kernel **disappears** when its package is replaced — so an absent
`/usr/lib/modules/$(uname -r)` means the upgrade already happened underneath you.

Same shape, not measured here, in rough order of how much silence they break:

| Watch | Where the answer comes from |
|---|---|
| failed systemd units, system and user | `systemctl --failed --plain --no-legend`, one bucket per unit |
| a backup that has not run | age of the newest `restic`/`borg` snapshot, one bucket when older than N days |
| Syncthing conflicts and errored folders | its REST API, or `find` for `*.sync-conflict-*` |
| pending package updates | `pacman -Qu` — and `checkupdates` if you want it to be true rather than merely current |
| firmware updates | `fwupdmgr get-updates` |
| a filesystem over its threshold | `df`, emitting a bucket only past 90% |
| disk errors | `smartctl -H`, btrfs `device stats`, `zpool status` |
| peripheral batteries | `upower`/`solaar`, a bucket only under 15% |
| certificates about to expire | the issuing service, or `openssl s_client` |

The pattern to copy is the threshold: **emit no bucket at all in the normal case.** A provider
that always prints something has quietly turned into a monitor, which is the next section.

## Anti-patterns

- **Unread counts.** The premise of the whole plugin, in `README.md`'s second line.
- **Always-on gauges** — CPU, RAM, network throughput, disk usage as a percentage. The
  registry has dozens of monitors that do this properly, with graphs. A badge that is never
  empty stops being read within a day.
- **Anything that fires faster than you can act on it.** If you cannot plausibly deal with
  every event, the count is decoration.
- **Anything whose own tray icon already works and carries a real badge.** Rare, but it
  happens — check before writing a provider.
- **Feed readers.** Unread by construction: the whole point is that items pile up.

## What the format cannot do yet

Each of these is a real limit met while building providers, not a hypothetical:

- **There is exactly one reset: window focus.** Anything windowless and event-shaped — a
  finished build, a webhook, a script — therefore has no natural way to say *dealt with*. The
  workaround is to model it as `state` instead, which is usually the better design anyway, but
  not always available.
- **The widget cannot clear one target.** Right-click clears everything; a single target needs
  `dms ipc call attentionBadges clearOne <id>`. The popout is read-only.
- **A bucket is a name and a count, with no urgency.** A provider cannot say *this one is
  red* — a disk at 99% renders exactly like one at 91%.
- **Notification parsing is a localized string match**, so a bucket regex is one UI translation
  away from dumping everything into the fallback. Test it against real wording, and against
  wording it must *not* match.
- **No backoff.** A failing command is re-spawned every `intervalSeconds` forever. Keep the
  interval honest for anything that leaves the machine.

An exit code is informational, not fatal: a command that prints valid buckets **and then exits
non-zero** is applied normally, and the code is only recorded. Exit status alone decides
nothing unless nothing was printed — which is reported as `produced no output; exit code N`,
distinct from a clean empty answer. That distinction is deliberate: those two look identical in
the bar and mean completely different things.
