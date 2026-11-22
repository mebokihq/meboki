# Updates and releases

## How updates work

Official builds update themselves through [Sparkle](https://sparkle-project.org): one check a day (Settings › General › Updates turns it off), nothing about you is sent, and every update is signed.

A build you make yourself has no updater. `Scripts/make-app.sh` adds one only when `MEBOKI_FEED_URL` and `MEBOKI_UPDATE_KEY` are set.

## Try the updater locally

```sh
Scripts/test-update.sh            # installs the current version with a local feed, serves a newer test build
# in the app: right-click the menu-bar icon › Check for Updates…
Scripts/make-app.sh --install     # afterwards: back to the plain build
```

## What's new

After an update, Meboki shows a window with what changed since the version the user ran before. Its text is written by hand for every release in `App/WhatsNew/whatsnew.json`, newest entry first:

```json
{
  "version": "1.0.7",
  "date": "2026-11-24",
  "highlights": [
    { "kind": "new", "symbol": "doc.text", "title": "Short title", "body": "One or two sentences.", "image": "images/1.0.7-example.png" }
  ],
  "items": [
    { "kind": "fixed", "text": "One line per smaller change." }
  ]
}
```

For a release that should show no window (a small fix release), add only `{"version": "1.0.7", "date": "2026-11-24", "hidden": true}`. Users who skipped versions still see the entries before it.

`kind` is `new`, `improved` or `fixed`; `symbol` (an SF Symbol) and `image` (a PNG under `App/WhatsNew/images/`, shown up to 220 pt high) are optional. `Scripts/check-whats-new.py` checks the file: every build stops on a broken file, and `release.sh` stops when the top entry isn't the version being released, has the same text as the entry before it, or the file hasn't changed since the last release tag. Preview it with `swift build && .build/debug/Meboki --whats-new-demo [--from 1.0.5] [--changelog] [--dark]`. Settings › About › Changelog shows every entry with text in the same window.

### Before every release

1. Read what changed since the last release: `git log $(git tag --sort=-v:refname | head -1)..HEAD`.
2. Decide: **update** the screen, or **hide** it for this release.
3. Update: add an entry at the top of `App/WhatsNew/whatsnew.json` with the new version and today's date. One to three highlights for what users will notice, items for the smaller changes. Write for users, not commit subjects. Screenshots go in `App/WhatsNew/images/`.
   Hide: add `{"version": "x.y.z", "date": "yyyy-MM-dd", "hidden": true}` at the top.
4. `Scripts/check-whats-new.py x.y.z` and `.build/debug/Meboki --whats-new-demo` to check and preview, then commit.

## Make a release

```sh
Scripts/release.sh <version> <build> [--notes notes.html] [--publish]
```

Settle the What's new entry first (above); `release.sh` stops without it. Without `--notes`, that entry is also the text of Sparkle's update window. This makes a Developer ID build with the updater on, notarizes and staples it, wraps it in a signed and notarized DMG, and writes the `appcast.xml` that announces it (signed with the update key from the login keychain). `--publish` tags the commit and creates the GitHub release with both files. The script lists what it needs at the top.
