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

## Make a release

```sh
Scripts/release.sh <version> <build> [--notes notes.html] [--publish]
```

This makes a Developer ID build with the updater on, notarizes and staples it, wraps it in a signed and notarized DMG, and writes the `appcast.xml` that announces it (signed with the update key from the login keychain). `--publish` tags the commit and creates the GitHub release with both files. The script lists what it needs at the top.
