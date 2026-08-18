# dms-attention-badges — session hand-off

A DankMaterialShell (Quickshell/QML) plugin. **User-facing docs are in `README.md`** — what the plugin does, how to install it, its known limits and the provider roadmap. This file holds what the next session needs and the README should not carry: the DMS plugin API as *measured*, and the traps found while writing it.

It is kept in the public repo deliberately — the API table below was read out of a running shell rather than out of documentation, so it is probably useful to anyone else writing a DMS plugin, whether or not they care about badges.

`PROVIDER-IDEAS.md` is the third document and answers the question a host with no providers inevitably raises: *what do I point it at?* It carries the fit test, the anti-patterns, and — the part to keep honest — a list of what the format still cannot express, which is the real roadmap. Its two worked `command` examples were run end to end through `parseProvider` and `parseCommandOutput`, in both the empty and the populated branch; anything in it that was *not* measured says so.

Everything below was read out of the shipped shell at `/usr/share/quickshell/dms` (`dms-shell 1.5.3-1`, `quickshell 0.3.0-2.1`) — that tree is the primary source and beats both memory and the online docs. `PLUGINS/` in it ships worked examples, a `plugin-schema.json` and a theme reference.

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
| cross-plugin state | `PluginService` has **no access control**: `loadPluginState`/`savePluginState` take an explicit `pluginId`, so any plugin can read or write any other's state. Useful, and a reason not to treat plugin state as private |
| scanning a directory | `Qt.labs.folderlistmodel` works — it ships in `qt6-declarative`, which both `quickshell` and `dms-shell` depend on, and DMS itself uses it in `Common/I18n.qml:36`. No shipped example plugin does, so it was an assumption worth checking |
| dynamic children | `Instantiator` over a model, with `FileView`/`Timer` delegates carrying `required property var modelData`, is how per-item `FileView`s and per-item pollers are built. A `Process` nests fine as `property Process proc: Process { … }` inside a `Timer` delegate |
| settings page | `PluginSettings` is an `Item` with `default property list<QtObject> content`; `onContentChanged` reparents each `Item` child into its internal column, so a **`Repeater` works as a child** and its delegates land in that column. `ToggleSetting` self-initialises (`Component.onCompleted: Qt.callLater(loadValue)`) and `findSettings()` walks up parents, so Repeater-created toggles load and save correctly |
| settings timing | `pluginService` is assigned **after** construction — `Component.onCompleted` alone reads `null`. Handle `onPluginServiceChanged` too, or the page stays permanently empty |

`import qs.Services` works from a plugin, so `NotificationService`, `CompositorService`, `ToastService` and the rest of the shell's singletons are directly available.

## Traps

- **There is no working QML checker.** `qmllint` and `qmlformat` from qt6-declarative 6.11 exit non-zero on *shipped, working* DMS files that use `?.`/`??` (verified against `Services/ClipboardService.qml`). Do not add one and do not trust one — but see § "`qmllint` is not useless after all" for the one narrow syntax-only use that does discriminate, and which is worth running before handing QML over.
  - The first attempt at a gate was worse than none: `qmllint --bare` is not a valid option in this version, so every file printed `Unknown option 'bare'`, a grep for `Error` counted zero, and three files "passed". **A tool that rejected the invocation reads exactly like a tool that found nothing.** Check the exit code, and run a deliberately broken file as a control before believing any gate.
- **`parseProvider` returns `{target, errors}` — an array named `errors`, not a singular `error`.** A test written as `check(…, parsed.error || "", "")` compares `undefined` to `""`, passes for *every* input, and reads as a green validation check; a deliberately invalid provider sailed through it (2026-08-15). `target` is `null` on failure, which is the other signal to assert. Same family as the `qmllint --bare` trap below — the control run is what caught both, and it is the step most easily skipped when the check "obviously" works.
- **`Rules.js` is plain JS on purpose** — no `.pragma library`, and a guarded `module.exports` tail so `scripts/test` can `require()` it under node. That is the only automated coverage this repo has; keep logic out of the QML so it stays that way.
- **Window classes come from a live window**, `hyprctl -j clients | grep -i class`, never from a `.desktop` file. Thunderbird advertises `StartupWMClass=thunderbird` and actually maps as `org.mozilla.Thunderbird`; the notification's `desktopEntry` happens to equal the window class for it, which is what makes the notification↔focus join work with no mapping table. Not universally true — Brave notifies as `brave-browser`.
- **First run must seed `lastSeenTs = Date.now()`.** Folding the stored history instead would greet a fresh install with a badge counting the last 7 days of notifications.
- **Notification history is capped and prunable** (`notificationHistoryMaxCount` 50, `MaxAgeDays` 7, and it can be disabled). It is the *arrival hook* only — the counts are ours and are persisted separately, deliberately.

## Why herdr is a state target, not a counter (2026-08-11)

The first version counted herdr from its notifications and **the number only ever grew** — correctly, and uselessly. The reset fires on `activeToplevelChanged`, and you are normally *already focused on herdr* when an agent blocks, so no focus change ever happens. Clearing on arrival instead would have pinned it at zero. **Window focus cannot express "I dealt with that pane"** for an app you live inside; that is a granularity limit, not a bug, and no amount of tuning the counter fixes it.

The fix was to change the model. `mode: "state"` targets are *replaced* on every provider poll rather than accumulated, so they cannot drift and need no reset: a pane leaves the badge when its agent stops being blocked. `matches()` returns false for state targets so the notification stream cannot double-feed them.

**`herdr api schema --json` works with no running server** — it is bundled in the binary — so `SessionSnapshot`, `AgentInfo` and the `AgentStatus` enum (`idle`/`working`/`blocked`/`done`/`unknown`) are measured, not guessed. Use it before touching anything herdr-shaped; `herdr agent list` and `herdr api snapshot` both need the socket and are therefore blocked in the sandbox.

**But the schema describes the payload, NOT the CLI's framing — and that cost a full round of testing (2026-08-11).** `herdr api snapshot` prints the socket *response envelope*: `{"id":"cli:api:snapshot","result":{"snapshot":{ … }}}`. Reading `.agents` off the top level therefore succeeded at every step — the command ran, the JSON parsed, no error was raised anywhere — and simply found zero agents forever. The badge sat at 0, which is also what "nothing is waiting" looks like, so three polls' worth of evidence said nothing. **A schema is authoritative for the shape of a message and says nothing about how a CLI wraps it**; capture one real line of output before writing a parser, and when a value cannot be captured, make the code report what it *did* see (`herdr poll: … bytes, parsed=…, agents=…`, plus a histogram of the statuses) rather than only its verdict. That diagnostic named the cause in one command after three rounds of ranked guessing.

**The status histogram was nearly lost in the move, and is now on stderr (2026-08-15).** The diagnostic this section praises — *"report what it did see, plus a histogram of the statuses"* — existed only in the old daemon's herdr block, and rewriting that block generically deleted it. It is back in `providers/herdr-attention` as `describe()`, printed on **stderr on every poll**, because stdout is the bucket contract and a diagnostic there would corrupt it invisibly:

```
herdr-attention: 3 agents [blocked=2 idle=1], watching blocked,done, focused=p9 -> 1 buckets
```

The daemon keeps the last stderr line per target and prints it in `status()`. Two tests guard the split (stdout is exactly one JSON line and contains no diagnostic text; stderr contains it), because a leak would only surface as a badge that silently stopped working. **Generalising a special case is where diagnostics go to die** — the new code was better in every structural way and quietly less debuggable, which is exactly the trade nobody notices at review time.

**Where this code lives now (2026-08-15):** all of it moved out of `Rules.js` into `providers/herdr-attention`, the worked example of a command provider — `unwrapSnapshot`, `herdrBuckets`, the status vocabulary and the `●`/`✓` marks. The core kept only `parseCommandOutput`, which validates the generic `{"buckets": …}` contract. Everything above still applies verbatim, just one file over; the envelope regression test moved with it and runs the real script end to end through its real entry point.

## The Thunderbird bridge is a RESET provider, not a full one

Originally scoped as "the extension owns per-account counts and resets". It shipped much smaller: the notification counts were already accurate, so duplicating them in the extension would have created a second source of truth for the same number. The extension sends **only the thing the desktop cannot see** — which account you opened.

Consequences to keep in mind when changing either side:

- `state.visitsSeen` is the plugin's memory of which visits it already acted on. **Every state helper must preserve keys it does not own** (they use `Object.assign({}, state, …)` for this) — an earlier version rebuilt the state object from `{lastSeenTs, targets}` and would have silently dropped `visitsSeen` on the next notification, making each file read look new and re-clearing a bucket that had just counted mail.
  - **And the restore path had exactly that bug the whole time (found 2026-08-15).** The helpers were fixed; `Component.onCompleted` still rebuilt state as `{lastSeenTs, targets}` from the persisted copy, so every shell restart dropped `visitsSeen` and re-cleared on the next file read. A rule applied to the code it was written about and not to the code beside it — worth checking the *other* constructors of a shape whenever such a rule is recorded.
- **The file existing is the switch**, not a setting. No file ⇒ the old focus-clears- everything behaviour, which is what makes the bridge safe to uninstall. Older than 7 days ⇒ treated as abandoned.
- **Nothing about the mechanism is Thunderbird-specific any more.** It is `reset.perBucketFile` on any counted provider, and a "bucket" is whatever that provider's regex produced. The daemon no longer contains the string `"thunderbird"` anywhere; the focus-clear exemption keys off `target.perBucketFile && perBucketLive[target.id]`.
- The bridge reports **every identity of the visited account**, because mail arrives at aliases and buckets are keyed by whatever address the notification named.

## Why this is not two systray apps (settled 2026-08-15)

Revisited from scratch: should the Thunderbird half and the herdr half be small independent tray applications instead of one DMS plugin, and does something already exist? **No, and mostly no.** All of the below is measured, not recalled — re-read it before re-opening the question.

### Thunderbird ships a Linux tray now, and it is empty

`thunderbird 153.0.2-2.1` contains a real StatusNotifierItem implementation — `rust/sys_tray/src/linux/{mod.rs,system_tray.rs}` in comm-central, built on `ksni`, registering with `org.kde.StatusNotifierWatcher`, compiled into `libxul.so` (confirmed by `strings -a libxul.so | grep sys_tray`). Read the source at the version we run (`gh api repos/mozilla/releases-comm-central/contents/rust/sys_tray/src/linux/mod.rs`), not the release notes — it does nothing useful:

| | state in 153 |
|---|---|
| `update_unread_count` | **no-op stub** — `// (unimplemented as yet)`, body `Ok(())` |
| tray menu | one item: **Quit** |
| JS side | `MailNotificationManager.sys.mjs:159` — `// We don't have indicator for unread count on Linux yet.`; the count listener is registered only for `["macosx", "win"]` |
| enablement | gate is `mail.biff.show_tray_icon_always`, **default `false`** (`defaults/pref/mailnews.js:372`), **no UI** — the Settings checkbox drives `mail.biff.show_tray_icon`, which `MailGlue.sys.mjs:1525` registers only `if (AppConstants.platform === "win")` |

So an icon exists and carries no information. Flip the pref in about:config to see it. Measured the same day: `busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems` → `as 0`. The watcher is up (the property read succeeded, so Quickshell is hosting it) and **nothing on the machine registers a tray item at all** — TB included, as the pref default predicts.

Aside, relevant to the open DND question below: TB's own Linux DND check reads **GNOME GSettings** (`org.freedesktop.Notifications Inhibited`, `org.gnome.desktop.notifications show-banners`), so under Hyprland/DMS it always reads the default and TB never suppresses.

### Birdtray is the model this plugin exists to reject

AUR only (`paru -Si birdtray`), 1.11.4, deps `qt5-svg qt5-x11extras`, **last release 2023-09**. Its README: it reads the **mork database** and renders an **unread counter** with per-account colours. That is exactly what `README.md`'s second line rules out. Wayland show/hide is unresolved upstream (issues #426, #584 open; #611, #612 open).

For herdr nothing exists at all: `strings /usr/bin/herdr` has no `StatusNotifier`, `ksni` or `tray` strings, so that half would be written from zero — and it would be the same poll loop this plugin already runs, plus a hand-rolled Hyprland focus listener.

### The decisive part: SNI cannot carry this payload, and our own bar drops the one channel that could

`quickshell-service-statusnotifier.qmltypes` exposes `icon`, `title`, `tooltipTitle`, `tooltipDescription`, `status`, `menu`, `activate`, `scroll` — **no OverlayIcon, no AttentionIcon, no numeric badge**. And `Modules/DankBar/Widgets/SystemTrayBar.qml` never reads the SNI `status` property (every `status` hit in that file is `Image.status`), so `NeedsAttention` is ignored and `Passive` items are not hidden.

Consequence: `mk@…: 2, other@…: 1` and herdr's `●2 ✓1` could only be shown by **drawing text into a 16–24 px pixmap** (birdtray's approach) or by hiding it in a hover tooltip. The clear-on-focus reset, which comes free from `ToplevelManager.activeToplevel.appId`, would have to be reimplemented against the Hyprland IPC socket in each app.

### What a tray app would actually buy

One real thing: **portability off DMS**. If the shell is ever abandoned, a tray app survives and this plugin does not. Against that: every machine this runs on is Hyprland+DMS and provisions the plugin from a shared DMS baseline, and the registry is the distribution path.

The other argument — *two unrelated concerns should not be one plugin* — is already answered by the provider model: `notifications`, `herdr` and the bridge are separate providers behind one renderer. Splitting them into processes buys separation we have and costs the shared focus/reset machinery.

**Net effect of the research: it strengthens the case for publishing**, because there is now demonstrably no existing tool that does *new since you last looked*, per account, on Wayland.

### The nearest neighbours in the registry (2026-08-15)

Checked before publishing, because "isn't this just X?" is the first question a reviewer asks. Of ~290 entries the closest is **Interval Command** (`corcoran/dms-interval-command`) — *"run a command on a custom interval and display its output in the bar"*. It is the same poll loop and stops there: output is text, not buckets; there is no notification source, no focus reset, and no since-you-last-looked semantics, which is the entire idea here. The mail-shaped ones (`mailChecker`, `dankmailUnread`) and the forge-shaped ones (`githubNotifier`, `gitlabNotifier`, `githubInbox`) are each **one hard-wired service**, which is precisely what the provider model replaces — and any of them is expressible here as a JSON file. Nothing found does both halves.

## TODO

**1. Publishing to the DMS registry — possible, and the path is concrete.** The registry is a git repo, `github.com/AvengeMedia/dms-plugin-registry` (85 stars, active), not a web form: fork it, add `plugins/mkoester-attention-badges.json` naming this repo, open a PR. Its `CONTRIBUTING.md` requires `id` and `name` to match `plugin.json` exactly — `attentionBadges` and `Attention Badges` already satisfy the id rules (camelCase, letters only). `dms plugins install` then clones the repo named in that entry, and the API is `api.danklinux.com/plugins`.

**The entry is written and lives at `docs/registry-entry.json`** — copy it into a fork as `plugins/mkoester-attention-badges.json`. It is kept in-repo so a version bump can be diffed against what was submitted, and `scripts/test` asserts its `id`/`name` still match `plugin.json`, which is the one thing the registry rejects a PR over and only checks in CI.

Re-checked 2026-08-15 against `CONTRIBUTING.md` — still accurate, and there is more than was noted. The entry additionally **requires** `capabilities`, `category`, `compositors`, `distro` and a reachable `screenshot` URL; `path` is optional and would allow a monorepo. The registry ships **local validators to run before opening the PR** — `pip install jinja2 requests`, then `python3 .github/generate.py --validate` and `python3 .github/validate_links.py`. Read 2026-08-15 rather than taken from `CONTRIBUTING.md`, because they **split differently than the prose suggests**: `generate.py` checks JSON syntax and its own required-field list, which does **not** include `screenshot`; everything else is `validate_links.py` — the screenshot's presence *and* reachability, the camelCase rule, and the `id`/`name` match, which it makes by fetching `plugin.json` from `raw.githubusercontent.com`. **Both network checks fail while the repo is private**, so a green `generate.py` alone means very little. The offline half of the same comparison is in `scripts/test`, which needs no network at all.

Every plugin also gets a standardised 960×540 preview card at `api.danklinux.com/previews/{id}`, which letterboxes any aspect ratio over a blurred backdrop, so the screenshot does not need cropping — capture it on the default dank purple theme with real data visible.

**Do not spend time on `I18n.tr()` for this plugin.** It reads like the obvious publish-readiness item and is nearly worthless: `Common/I18n.qml:120` falls back to returning the key, and its catalog is loaded *only* from `translations/poexports` inside the DMS install (`FolderListModel`, line 27). **There is no mechanism for a plugin to register its own translations**, so every plugin-specific string stays English forever, translated or not. Wrapping is worth it only for terms DMS's own catalog already carries (`Add`, `Enabled`).

**2. ~~De-personalise before publishing~~ — DONE 2026-08-15, and it went further than de-personalising.** See § "The provider framework" below.

**3. Publish-readiness pass — DONE 2026-08-15.** MIT `LICENSE`, `plugin.json` at 1.0.0 with `process` in `permissions` (a `command` provider spawns one, and the schema's enum has the term), HTTPS clone URLs in the README, both install routes documented, and this file de-personalised. `plugin.json` was checked field-by-field against the shipped `plugin-schema.json` — required keys, every `pattern`, every `enum` — with a deliberately broken copy as the control, because `python3-jsonschema` is not installed and pypi is unreachable from a sandboxed session.

**Screenshot: provided 2026-08-15** and committed at `docs/screenshot.png`, also embedded in `README.md`. Two caveats recorded rather than fixed, both in `docs/README.md`: it is **507×233**, and the registry letterboxes into a 960×540 card, so it is upscaled ~1.9× and looks soft; and the mail addresses are **blurred**, which in a gallery listing advertises that something is hidden at exactly the spot where the per-account split is the feature. Regenerating with fake data beats redacting real data — `clear`, then the `notify-send` line 2–3× with `@example.com` addresses.

**What is left needs a human: making the three repos public.** The registry entry is a public GitHub URL that `dms plugins install` clones, and `validate_links.py` fetches both that repo and the screenshot, so neither network check can pass before the flip.

## The provider framework (2026-08-15)

The reframe to preserve: **the plugin is a host, not a bundle of two features.** It knows *how* to watch things and nothing about *what*. Thunderbird and herdr are two ordinary providers, and nothing in the QML or in `Rules.js` names either of them.

A provider is a **JSON file** in `~/.config/DankMaterialShell/attention-providers/`, not code and not a second DMS plugin. Since 2026-08-15 the normal form is **one git clone per provider, in its own subdirectory, carrying `provider.json`** — see § "The split" below. `README.md` is the format's reference; what belongs here is why it is shaped this way:

- **Data, not code, was chosen over two alternatives.** A provider-as-DMS-plugin would need its own `plugin.json`, QML and registry entry each, and would break the single-writer invariant (note `PluginService` has **no access control** — `savePluginState(pluginId, …)` lets any plugin write any other's state, so that route was possible, not advisable). A mini query language in the file was the third option, rejected as inventing a language.
- **A `command` provider prints its own buckets** — `{"buckets": {"<name>": <count>}}` — so extraction lives in the producer, not in the core. This is what let `herdrBuckets()` and `unwrapSnapshot()` leave `Rules.js` entirely; they now live in `providers/herdr-attention`, still under `scripts/test`. Without this the core would have kept a function called `herdrBuckets`, and "use-case agnostic" would have been a slogan.
- **The scanned directory is a sibling of `plugins/`, not a subdirectory of the plugin.** The plugin directory is a symlink to this checkout, so user provider files would otherwise land in the repo.
- **Shipped presets in `providers/` are examples, not defaults.** A fresh install badges nothing. `scripts/test` loads them from disk, so a broken preset fails the suite instead of failing silently in the bar.
- **`$XDG_*`/`~` expansion is the core's job** (`Rules.expandPath`, applied to `perBucketFile` *and* to command arguments), because a provider file carrying an absolute home path could not be copied between machines.

### The split (2026-08-15)

Each provider is now its own repo, cloned into the scan directory. The plugin repo ships no provider at all.

| Repo | Cloned to | Kind |
|---|---|---|
| `dms-attention-badges-tb` | `attention-providers/thunderbird` | `notifications` |
| `dms-attention-badges-herdr` | `attention-providers/herdr` | `command` |

`thunderbird-attention-bridge` **stays its own repo**, unchanged — the tb provider works with no bridge at all, and `visits.json` remains the only interface between them.

Three things worth keeping:

- **The deployed clone IS the working copy** — a provider repo is cloned straight into the scan directory and edited there, with no second checkout anywhere. That is what makes `$PROVIDER_DIR` sufficient and the install a bare `git clone`.
- **A fixed `provider.json`, not "any \*.json one level down".** A repo's `README.md`, `package.json` or fixtures could otherwise be parsed and reported as broken providers.
- **`$PROVIDER_DIR` is what makes a clone self-contained** — no symlink, no PATH entry. It has no default, so a flat provider file using it fails loudly at spawn instead of quietly resolving to some other binary of the same name.

The thin repo earns its tests. `dms-attention-badges-tb` is one JSON file, and its suite asserts the bucket regex against real Thunderbird wording *and* that it rejects German phrasing, the connection-error notification, and summaries that merely contain the phrase — because that regex matches a **localized UI string** and fails silently, dumping every mail into `other`.

### Updating providers is the user's problem, and `scripts/providers` is the answer (2026-08-16)

Once the plugin shipped through the registry, "how does a stranger update the providers they cloned?" had no answer — `dms plugins update` covers the plugin and knows nothing about the scan directory. `scripts/providers update` fast-forwards every provider clone; `install` clones one and prints the `rescan`. Three decisions worth not re-litigating:

- **Manual, not a timer or a daemon job.** DMS updates plugins only when asked (`dms plugins update [-a] [--check]`), so an auto-pulling provider would be *more* automatic than the host it plugs into, and it would put network fetches inside the shell.
- **`--ff-only`, always.** The deployed clone *is* the working copy (§ The split), so a provider someone has edited must be reported and left alone rather than merged behind their back. A refusal sets the exit status, which is what makes the script usable from a larger update routine.
- **It names no provider and no home path**, like the rest of the host: the scan directory comes from `$DMS_ATTENTION_PROVIDERS_DIR` or `$XDG_CONFIG_HOME`, which is also what lets `scripts/test` point it at a throwaway fixture.

**The control run is the part that earned its keep.** The suite went green with `--ff-only` deleted from the script — because the fixture's divergence edited `provider.json` on *both* sides, so an unrestricted `git merge` hit a conflict and failed for its own unrelated reason. The assertion could not distinguish the policy it existed to check from a merge that happened to break. Fixed by making the two sides touch **different files**, so git *could* merge them cleanly, plus an assertion that the upstream commit did **not** arrive. Same family as the `parseProvider.errors` trap above: a check that cannot fail reads exactly like a check that passed, and only a deliberately broken copy tells them apart.

### Traps met building it

- **Publishing only the *enabled* targets to the other surfaces is a trap.** The daemon owns the provider scan and publishes the list under the `renderTargets` state key, because the widget and the settings page are separate instances that must not scan the directory themselves. It must publish **every valid provider plus the invalid ones** — the settings page draws its toggles from that list, so a provider disabled once would vanish from the page and could never be switched back on. Caught before it shipped, but only just.
- **The old `Component.onCompleted` silently dropped `visitsSeen` on restore.** It rebuilt state as `{lastSeenTs, targets}`, so every shell restart made the next bridge file read look new and re-cleared a bucket that had counted mail since the visit. Exactly the failure the state-helper rule in § "The Thunderbird bridge" warns about — the helpers were fixed for it and the *restore path* was not. Fixed 2026-08-15.
- **An invalid provider file must be visible, never skipped.** It renders identically to an app that simply has not notified yet. Both `status()` and the settings page list the filename and the reason, and every validation error in `parseProvider` is phrased to be read by whoever wrote the file.
- **A command provider must be given an ABSOLUTE path, and the daemon must record a poll from three signals, not one (second run, 2026-08-15).** `status()` said `poll: never` for herdr, which was true of the *record* and told us nothing about why: `lastPoll` was only ever written from `stdout`'s `onStreamFinished`, so a command that could not be **spawned** produced no stdout, wrote no record, and printed the identical line to *"the timer never fired"*. Two unrelated bugs, one symptom. Now `_pollStarted` / `_commandFinished` / `_commandExited` (via `Process.onExited`, which carries `exitCode`) each write, and `status()` distinguishes `NEVER STARTED` from `started …, nothing came back yet` from a real poll with its exit code, and prints the fully expanded command. **The likely cause, still a hypothesis rather than a measurement:** DMS runs from `/usr/lib/systemd/user/dms.service`, which sets no `Environment=PATH`, and there is no `PATH` in `~/.config/environment.d/` — so the unit gets the *user manager's* `PATH`, which does not include `~/.local/bin`, and a bare `herdr-attention` cannot be found even though the symlink is there and works in a terminal. Providers now address their own scripts through `$PROVIDER_DIR`, which is what command-argument expansion was added for and which removes the question entirely. The daemon's environment cannot be read from a sandboxed session (its own PID namespace), so the `exit code` line in `status()` is what would actually settle it.
- **`StandardPaths.writableLocation` returns a URL, and `FolderListModel` answers a malformed one by scanning the working directory (first run, 2026-08-15).** `"file://" + <url>` gave `file://file:///home/…`; the model raised nothing, fell back to the process CWD, and the first `status()` confidently reported *"0 valid, 1 invalid — INVALID package.json"* — a file from an unrelated directory, described as a broken provider. **A bad path here does not fail, it succeeds against the wrong directory**, which is far harder to spot than an empty result. Three defences now, because one was clearly not enough: `Paths.strip(Paths.config)` / `Paths.toFileUrl()` instead of hand-built URLs (`Common/Paths.qml:47,51`); a `_isOurs()` guard rejecting any enumerated path not under `providersDir`, reported as `STRAY` by `status()`; and `Paths.mkdir` at startup, since a *missing* directory triggers the same fallback. `status()` also prints the raw `*.json` count now, so "scanned nothing" and "scanned the wrong place" are distinguishable at a glance.

### `qmllint` is not useless after all — but only as a syntax smoke test

The § Traps entry above still stands for **semantics**. But the exit code *does* discriminate once the known false positive is removed, and that is worth one command before a hand-over:

```sh
sed 's/?\.//g; s/ ?? / || /g' File.qml > /tmp/x.qml && qmllint /tmp/x.qml >/dev/null 2>&1; echo $?
```

Measured 2026-08-15: `AttentionDaemon.qml` exits **255** as shipped and **0** with `?.`/`??` neutralised, i.e. its 255 is entirely the documented false positive and there is no syntax error. `ClipboardService.qml` (shipped, working) also exits 255, which is why the raw code means nothing on its own. **Two riders, both learned the hard way in the same session:** `qmllint` prints *nothing at all* here — no stdout, no stderr — so any grep over its output matches nothing and reads as a clean pass, which is the `--bare` trap in a new costume; and run a deliberately broken file as a control first, because a filter that cannot fire looks exactly like a filter that found nothing. This catches typos and unbalanced braces. It says nothing about bindings, missing properties, or whether `Instantiator` does what you think.

## Unverified / open

- ~~Whether **do-not-disturb** suppresses entries from reaching `historyList`~~ — **settled 2026-08-15 by reading the source: it does not.** In `Services/NotificationService.qml`, `SessionData.doNotDisturb` only gates `shouldShowPopup` (line 717). History is fed from `shouldKeepInCenter` (`!isTransient && !policy.hideFromCenter`, line 718), and the `addToHistory` call at line 742 sits behind *that*, not behind the popup flag. So a DND window is fully visible to the counter. **The real blind spot is `transient`**, not DND: a notification with the freedesktop `transient` hint is dismissed at line 721 and never reaches history, DND or no DND. **Thunderbird does not set it — checked 2026-08-15, two ways.** Empirically, `~/.cache/DankMaterialShell/notification_history.json` held 6 live Thunderbird entries, which is only possible for non-transient ones. Mechanically, the Linux alert backend is `toolkit/system/gnome/nsAlertsIconListener.cpp`, and it sets exactly **two** hints — `suppress-sound` and `desktop-entry` (the latter is what puts `desktopEntry: "org.mozilla.Thunderbird"` in the history record, confirming this is the code path in use). A `search/code` for `transient` across both `toolkit/system/gnome` and `toolkit/components/alerts` returns 0, and the same query shape *does* find `suppress-sound` — so the empty result is a real absence, not a broken query. The `transient` string in `libxul.so` comes from elsewhere (GTK window parenting, xdg-shell), not from the alerts path.
- Whether Thunderbird's **calendar reminders** use the same app id and a third summary shape. None appeared in the 50-entry sample.
- ~~The widget has never been observed rendering~~ — **confirmed working 2026-08-11.** Both halves of the plugin are now verified end to end on real hardware: Thunderbird counting per account and clearing on focus, herdr badging `●`/`✓` and clearing itself, and the bar widget rendering both.
- ~~Whether `done` is observable long enough to badge~~ — **settled 2026-08-11, it is.** A finishing run showed `idle=2 done=1` with a `✓` bucket while the pane was unfocused, and returned to `idle=3` with an empty badge once opened. So `done` persists until you look, and viewing is what ends it. The earlier "probably too short-lived" reading came from a single snapshot taken *after* the pane had already been viewed — an absence measured at the one moment it was guaranteed to be absent.
- ~~The `mk.herdr` window class is still unconfirmed~~ — **moot since 2026-08-15.** A state target takes no `reset` block at all (`parseProvider` now rejects one), so no window class for herdr is stored anywhere. `status()` still prints the focused class, which is the way to read any window class off a live window.
- **OPEN: the scan sometimes comes up empty after `dms restart` — cause unknown (2026-08-15).** Observed once: `2 *.json seen` but `0 valid, 0 invalid`, no strays, on a shell where the identical QML had worked minutes earlier — **no QML changed between the working and failing runs**, so it is ordering or timing at startup, not a regression. Do not rank hypotheses at it; `status()` now reports the `FolderListModel` status and a **per-file lifecycle stage** (`delegate created, loading <path>` / `loaded` / `load failed` / `STRAY`) precisely because the old line could not separate four different bugs: no delegate created, delegate with an empty path, load still in flight, and load succeeded into a rebuild that produced nothing. Read the stage lines first. `dms ipc call attentionBadges rescan` re-runs the directory scan (as opposed to `reload`, which only re-parses what was already read) and is both the workaround and half the diagnosis — if rescan fixes it, the folder model resolved late.
- ~~Nothing in this rewrite has been loaded in a running shell~~ — **both provider kinds verified end to end in a running shell, 2026-08-15.** `FolderListModel` in a plugin and both `Instantiator` blocks work. Measured:
  - **`command` / `state`**: `1 agents [done=1] → ✓ extensions · 1 · claude`, then `1 agents [idle=1] → 0 buckets` once the pane was viewed. Note what the histogram bought: it showed the badge cleared because **herdr's own status changed**, not because the plugin dropped data — an empty badge looks identical either way, so this is the first time that distinction was actually observable.
  - **`notifications` / `count`**: forced with `notify-send --hint=string:desktop-entry:org.mozilla.Thunderbird "test@example.de received 3 new messages" x` → `Thunderbird: 3`, bucket `test@example.de`. That one command proves the match rule, the bucket regex **and** `countGroup` (3 came from the text, not from counting notifications), and needs no waiting for real mail — use it whenever the parse changes.
  - Still unexercised: the **per-bucket reset** (`perBucketFile`; the Thunderbird bridge has never been run at all), and the **settings page** `Repeater` of `ToggleSetting`.
