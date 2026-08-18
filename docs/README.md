# docs/

Two files that exist for the [DMS plugin registry](https://github.com/AvengeMedia/dms-plugin-registry), not for the plugin itself.

- **`registry-entry.json`** — the entry submitted to the registry, verbatim. It is copied to `plugins/mkoester-attention-badges.json` in a fork of that repo and opened as a PR; keeping the copy here means a later version bump can be diffed against what was actually submitted. Its `id` and `name` **must** stay identical to `../plugin.json` — the registry validates exactly that pair.
- **`screenshot.png`** — the image `registry-entry.json` points at by raw URL, and also the one in the top-level `README.md`. The registry requires a reachable screenshot and refuses the PR without one; it wraps whatever it gets in a standard 960×540 card, **letterboxed rather than cropped**, so the aspect ratio is free but the *resolution* is not: anything narrower than 960 px is upscaled into the card and looks soft. Capture the popout open with real data, and do not let a screenshot tool downscale the grab.

Two things to keep out of it. **Real mail addresses** — blurring them advertises that something is hidden, and the per-account split is the feature being shown, so fake the data instead: `dms ipc call attentionBadges clear`, then the `notify-send` line from the [Thunderbird provider](https://github.com/mkoester/dms-attention-badges-tb) two or three times with `@example.com` addresses. And ideally shoot it on the **default dank purple theme**, which is what the registry's own guidance asks for.

To validate before opening the PR, from a checkout of the registry fork:

```sh
pip install jinja2 requests
```

```sh
python3 .github/generate.py --validate
```

```sh
python3 .github/validate_links.py
```

Both validators reach the network — `validate_links.py` fetches the screenshot and the repo URL, so **it fails while the repo is still private**.
