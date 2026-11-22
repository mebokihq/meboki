# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**Meboki** is an open-source (GPL-3.0), local, Grammarly-like grammar checker for macOS. It checks English text in any app's text field with a local open-source LLM (Gemma 4 through a bundled `llama-server`), or on macOS 26 with Apple's built-in on-device model. Text never leaves the Mac unless the user turns on cloud. A menu-bar app for Apple Silicon, macOS 14+.

Quick start: `swift build && swift test`, then `Scripts/make-app.sh --install` to try the real app. The rules that matter most: all ranges are UTF-16, never write text you haven't verified, never read secure fields (see [Rules and invariants](#rules-and-invariants)).

### Check flow

- **Hotkey:** **⌃⌥G** checks the focused field, or the selection if there is one.
- **Automatic check** (`FocusTracker`, needs the local model and "Underline mistakes as I type"): the focused editable text area is checked after a typing pause or on focus. Underlines only; Esc mutes the field until focus moves; ignored fixes stay ignored (`IgnoredFixes`).
- **Live review:** after a whole-field check with the local model, typing keeps the review: fixes follow the text and edited sentences are checked again after a pause (`CheckScheduler`). With a selection or cloud, typing ends the review.
- **Fix keys:** ⏎ applies all, ⇧⏎ this one, ⇥ ignores, ← → move, Esc closes. Esc with no popup, or leaving the field, clears the underlines.
- **Skipped automatically:** single-line fields (except prose fields that only report as single-line: the Messages composer, Reminders titles and notes; `AX.isProseTextField`), apps set to Manual or Off (`AppRules`: terminals and code editors Manual, password managers and remote desktops Off), fields that hold nothing but code (`CodeDetector`; a field with prose and code is checked, its code blocks protected), and, with "Skip text that isn't English" on, foreign text (`LanguageGate`).

### Reading and writing fields

- Read text, selection and bounds only through `AX.text` / `AX.selection` / `AX.select` / `AX.bounds(el, range, text:)`, never `kAXValueAttribute` directly.
- Chromium `contenteditable` (x.com, Gmail, Notion, Slack, Obsidian) is measured through its static-text leaves (`TextLeafMap`). Mail compose (WebKit `AXWebArea`) uses text markers and is written by select + paste.
- Apps that give no text bounds get the card below the field instead of underlines.

### UI

- **Popups** (Settings › General): glass card, anchored bubble, or island (a dark capsule under the menu bar that takes ⏎ ⇧⏎ ⇥ ← → Esc and passes other keys on). Card and bubble show messages and the done line as glass toasts.
- **Menu bar:** left-click opens the popover (status, Check focused field, Pause in {App}, English, Check level, model row); right-click opens the debug menu.
- **Settings** (⌘,): General, Appearance (`ColorTone`, `DS.tone`), Writing, Models (local download with SHA-256 check; BYOK cloud), Apps (On / Casual / Manual / Off), Shortcuts, Privacy, Licence, About.
- **Writing settings:** the English variant (US/UK) picks the prompt once per session. Check for, Casual mode and Protect names/code/links are post-filters on the reply (`EditFilter`), never prompt text.
- **Onboarding:** first launch opens the Welcome window (Accessibility with a live-detected grant, model download only on button press, sample check). Reopen from the right-click menu or Settings › About.
- Windows the app opens on its own (notices, updates) never activate it, so the keyboard stays in the app being typed in.

### Models and cloud

- Local models download from pinned Hugging Face commits with SHA-256 (`ModelStore`). `ServerManager` runs `llama-server` on 127.0.0.1 with `-np 4 --kv-unified`, and unloads it when idle or under memory pressure.
- **Apple Intelligence (macOS 26+):** `ModelSource.apple` checks with Apple's on-device model (`AppleModelClient`, `FoundationModels`): a fresh `LanguageModelSession` per chunk, the same prompt as instructions, greedy, permissive-transformation guardrails; refusals and per-text limits leave the sentence unchanged, a lost model stops the check. On-device, so the automatic check and live review run with it; `llama-server` stops. Which backend a check uses is `ModelBackend.choose` (Core); `AppDelegate.checkBackend()` is the one factory. A fresh install (nothing stored, onboarding not done) starts on Apple's model where it is available (`Catalog.appleIsDefault`); a stored choice never changes by itself, and an unavailable Apple model is reported, not swapped. The framework is weak-linked: everything behind `#if canImport(FoundationModels)` and `#available(macOS 26, *)`, so the app runs on macOS 14 and 15. DEBUG: `--apple-model <state>` or `MEBOKI_APPLE_MODEL=<state>` forces the availability (available, notEnabled, modelNotReady, deviceNotEligible, osTooOld) in the app and the demos; a forced "available" on macOS 14/15 fails at check time with a message. Not benchmarked yet: `Scripts/make-bench-kit.sh` builds the kit for a macOS 26 Mac, `eval/bench_remote.py` scores what comes back.
- **Cloud (BYOK, opt-in):** with a key saved and **Use** pressed, checks go to OpenRouter or OpenAI through the Responses API (`ResponsesClient`) and `llama-server` stops. The UI shows a cloud symbol and the provider name.
- Long fields: benchmark page `docs/bench/long-field-300-fixes.html` (first check ~4 s, Apply all ~28 s). Apply all writes one group per paragraph run; `KeyGuard` holds keys while fixes are written.

### Licence

- 7-day trial (active days only), then free mode: the hotkey check with every model stays free; automatic check, bubble and island, Check level and Casual mode need a licence. Keys are checked offline (Ed25519, `LicenceKey`).
- `LicenceManager` joins the stored key, the revoked list and the trial clock into an `Entitlement`. **The check flow must read the `effective…` settings** (`effectivePopupStyle`, `effectiveCheckLevel`, `effectiveCasualMode`, `effectiveUnderlineAsYouType`, `effectiveAppMode(_:)`), never the stored ones. In free mode Settings keeps the stored values, dimmed with a lock.
- `meboki://activate?key=…` activates a key (`AppDelegate.handleActivationURL`) but never replaces a different working key.
- Notices: which one is due is a pure function in Core (`LicenceNotices`), shown by `AppDelegate.showDueLicenceNotices`. One Trial ended window, one per revoked or expired key, one last-day toast. Nothing else nags.
- Network: only a daily GET of the public revoked list, and only with a licence installed. Keychain access only on `TrialStore.queue`.
- DEBUG builds accept keys signed with the test signing key; release builds never do.

### Updates

- Sparkle 2, wrapped by `UpdateController`. Only a build whose Info.plist has `SUFeedURL` and `SUPublicEDKey` has an updater (`make-app.sh` adds them from `MEBOKI_FEED_URL` / `MEBOKI_UPDATE_KEY`); a plain build never starts Sparkle.
- One check a day, automatic install off by default. A found version shows as a dot on the menu-bar icon and a popover row, never as a window. Automatic install waits for a quiet moment (`UpdateTiming`).
- The correction popups carry a green update badge while a newer version waits (`UpdateNudge`): a pill from the day it's found, plus a banner with Install… from day 7. The found day is kept in defaults, so the badge survives relaunches and "Later"; it clears when a check finds the feed offers nothing newer. A click ends the review and opens Sparkle's window. No key reaches it.
- Releases are Developer ID builds, notarized and stapled, in a signed DMG with an appcast, made by `Scripts/release.sh` and published as GitHub releases. See [docs/releasing.md](docs/releasing.md).

## Documents

| File | What it holds |
|---|---|
| [README.md](README.md) | What Meboki is, install, usage, build from source, known limits. |
| [docs/self-signed-certificate.md](docs/self-signed-certificate.md) | The `Local Code Signing` certificate for local builds. |
| [docs/releasing.md](docs/releasing.md) | Sparkle updates, `test-update.sh`, `release.sh`. |
| [eval/README.md](eval/README.md) | Model and prompt benchmark: dataset, runners, reports. |
| `docs/bench/long-field-300-fixes.html` | Benchmark page for long fields (Chrome `contenteditable`, 12 009 characters, 300 fixes). Also read by `eval/bench_parallel.py`, `eval/language_report.py` and `eval/code_report.py`. |

Code comments cite design and plan sections (`PLAN.md §…`, `design_code.md §…`). Those documents are not in this repository.

## Architecture

```
App/Sources/Meboki/             menu-bar app (AppKit + SwiftUI), target "Meboki"
  AppDelegate.swift             debug menu, popover state, hotkey, check flow, pause gate, review session on a FixList (underlines or fallback card, apply / apply all / ignore), toasts, status pulse
  Accessibility.swift           AX read/write, app quirks, secure-input checks, paste fallback, ClipboardGuard, Log
  RichText.swift                text-marker adapter: AX.text / selection / select / bounds for any field (Chromium contenteditable via text leaves, WebKit editable web areas like Mail via text markers)
  VCLGeometry.swift             LibreOffice (VCL) quirk: element frames and text bounds flipped with the wrong screen height on several displays
  FieldProbe.swift              DEBUG `--probe-field <bundle id> [word …]`: what the adapter sees in an app's focused field
  Flow/Panels.swift             KeyPanel, HostedPanel (transparent non-activating panel, sync sizing), placement below the field
  Flow/Panels.swift             (also) PopupKeys: the shared popup keys ⏎ ⇧⏎ ⇥ ← → Esc
  Flow/GlassCardView.swift      glass card view + CardPanel (under a word, or below the field in the fallback)
  Flow/BubbleView.swift         anchored bubble view + BubblePanel (tip points at the word)
  Flow/PopupController.swift    picks card or bubble from AppSettings.popupStyle
  Flow/IslandView.swift         island HUD view + IslandPanel (style `island`: checking, review, done, messages)
  Flow/UpdateBadgeViews.swift   green update pill and banner on the card, bubble and island
  Onboarding/OnboardingWindow.swift   onboarding window (680 × 560), OnboardingModel (step, trust, engine, try state), AppMenus (window menu, accessory policy on close)
  Onboarding/OnboardingViews.swift    pages: Welcome, Accessibility (live grant), Model (download, disk space), Try it (sample check), Popup style (live preview), Done
  Onboarding/OnboardingDemo.swift     DEBUG `--onboarding-demo <step> [--dark] [--trusted] [--downloading]` for screenshots
  Settings/AppSettings.swift    UserDefaults-backed settings (popup style, writing options, appModes, checkedApps, hotkey, logEnabled, logSnippets, showInMenuBar, …)
  Licence/LicenceManager.swift  licence state (`entitlement`: licensed / trial / free), activation, `recordCheck` per real check, daily revoked-list fetch, `transitions`; Licence/LicenceStore (key + revoked list files), TrialStore (Keychain + UserDefaults), LicenceCLI (DEBUG `--licence-status`, `--verify-licence <key>`)
  Licence/LicenceDebug.swift    DEBUG: `DebugClock` (real time + an offset in UserDefaults), `DebugSigner` (test keys and revoked lists, signed with the test signing key from the login Keychain)
  Settings/Panes/DebugPane.swift  DEBUG: Settings › Debug: licence status, trial presets, clock jumps, onboarding reset, test keys, revoked-list tools (`make-app.sh --debug --install`)
  Licence/TrialEndedWindow.swift  the one-time notice window (trial ended / key no longer valid), `TrialEndedView`, `TrialEndedWindowController` (shown without activating)
  Licence/LicenceDemo.swift     DEBUG demos: `LicenceDemo` (own manager forced into a state), `TrialEndedDemo`, `PopoverDemo`, `DemoSnapshot`
  Settings/APIKeyStore.swift    BYOK API keys in the login Keychain (one item per provider)
  Settings/Shortcut.swift       recorded global shortcut (key code, Carbon modifiers, glyphs), macOS-shortcut conflict check
  Settings/SettingsWindow.swift Settings window (800 × 580 default, resizable to min 800 × 500, size remembered in `settingsWindowSize`; traffic lights in the glass sidebar, search, toast), SettingsModel, recorder key monitor
  Settings/SettingsComponents.swift  group, row, key field, footnote, app icon
  Settings/Panes/*.swift        General (style picker art), Appearance (tone cards, category chips, bubble preview), Writing, Models, Apps, Shortcuts (hotkey field), Privacy, Licence (status card, buy, key field, remove), About
  Settings/LicenceLock.swift    free-mode lock marks: `LicenceGate` (environment), `.licenceLocked(_:caption:)`, `NeedsLicencePopover`, `FreeModeBanner`; `DSSegmented(locked:onLockedTap:)`
  Settings/SettingsDemo.swift   DEBUG `--settings-demo <pane>` for screenshots (see the demo flags under Commands)
  Updates/UpdateController.swift  Sparkle wrapper: on only with a feed in Info.plist, gentle reminder state (`available`, `needsAttention`), the two switches, install at a quiet moment; DEBUG `MEBOKI_DEMO_UPDATE=<version>` (+ `MEBOKI_DEMO_UPDATE_DAYS=<n>`) fakes a found version for the demo flags and `--demo-popups --all`
  MenuBar/StatusItem.swift      status icon: left-click popover, right-click debug menu, icon states (checking, paused, update waiting, open)
  MenuBar/PopoverView.swift     menu-bar popover view + PopoverPanel (non-activating, under the icon): status, check button, tiles, model row
  Flow/UnderlineOverlay.swift   click-through overlay: wavy underlines, current/hover fill, applied flash, hit-test
  Flow/PopupPreview.swift       looping animated demo of a popup style (real card / bubble / island over a mini desktop): onboarding and Settings › General
  Flow/FocusTracker.swift       automatic check: follows the frontmost app's focused element (AXObserver focus + value)
  Flow/FieldWatcher.swift       review-session watcher: AXObserver (value, focus, move, scroll) + global monitors + tick
  Flow/ToastPanel.swift         glass toasts (done line, messages), auto-hide, Esc / click outside
  Flow/KeyGuard.swift           event tap (own thread) that holds ⏎ ⇥ arrows Esc while fixes are written; Esc stops Apply all
  Design/                       tokens, glass, shared components, DEBUG gallery
  ModelStore.swift              Catalog (pinned HF URLs + SHA256, `appleIsDefault`) and downloader (resume, checksum)
  AppleIntelligence.swift       Apple's built-in model in the app: availability (+ DEBUG override), corrector, System Settings link, status texts
  ServerManager.swift           bundled llama-server child process (127.0.0.1, random port, /health)
  HotKey.swift                  Carbon RegisterEventHotKey
  LegacyMigration.swift         one-time move of settings (dev.local.meboki, dev.local.proofreader) and of models, logs from pre-rename builds
Packages/Core/Sources/MebokiCore/        pure Swift, no AppKit, unit-tested
  Prompt.swift                  the benchmarked few-shot system prompt
  LLMClient.swift               `Corrector` protocol; OpenAI-compatible chat client for llama-server; detects truncated replies
  AppleModel.swift              Apple's on-device model (macOS 26+, weak-linked `FoundationModels`): `AppleModelAvailability`, `AppleModelError` (fatal or skip), `AppleModelClient`, output cap and truncation rule
  ModelBackend.swift            `ModelSource` (local / apple / cloud), `ModelBackend.choose` (which backend a check uses, or why none), `freshInstallSource` (Apple's model as the fresh-install default)
  ResponsesClient.swift         BYOK cloud: OpenAI Responses API with SSE streaming (OpenAI, OpenRouter), store off, ZDR on OpenRouter
  CloudCatalog.swift            CloudProvider (base URL, key shape) and the cloud models (reasoning/temperature settings, benchmark)
  PostFilter.swift              clean wrappers, similarity guard (Ratcliff/Obershelp = difflib), style-only filter
  Diff.swift                    word-level diff → UTF-16 `Edit`s
  ProofreadEngine.swift         ProofreadEngine: paragraph chunks → model → filters → edits
  CheckPipeline.swift           sentence cache (only changed sentence runs go to the model), cursor-first order, scope; CheckScheduler (typing pause, stale-pass cancel)
  FixList.swift                 fixes in any order (UTF-16 range shifting), n of N, card swap text and underline range (FixDisplay); live review: textEdited, reconcile; Apply all groups (one write per paragraph run)
  IgnoredFixes.swift            fixes the user ignored, by sentence, so later checks leave them out
  TextChange.swift              one contiguous change between two field values (common prefix/suffix, surrogate-safe)
  TextLeafMap.swift             lines up a rich editor's static-text leaves with its AXValue (UTF-16), splits ranges into leaf-local pieces
  FixCategory.swift             diff classifier (spelling / grammar / clarity / punctuation) + reason templates
  CheckOptions.swift            EnglishVariant, CheckLevel, CheckOptions (the settings a check uses)
  EditFilter.swift              settings post-filters on edits: casual text, slang, UK collective nouns, check level
  ProtectedTokens.swift         URLs, emails, @mentions, #tags, code, paths, identifiers, emoji, non-Latin words; `extra:` merges in the code blocks `CheckPipeline` / `ProofreadEngine` find once per check (off for a selection, `Scope.protectBlocks`)
  AppRules.swift                AppMode (on / casual / manual / off), the built-in skip list (terminals and code editors, password managers, remote desktops) with default modes, chat apps; CodeAppLearner (learned Manual: 3 code fields, no prose); the user's choice always wins
  CodeDetector.swift            precision-first line shapes: `scan` returns the verdict (a field that is code), the code blocks (runs of code lines with at least two strong lines, one blank line may sit inside; `blocks(in:)` on the whole text) and whether real prose is left outside them; the automatic check skips only a field that is code and nothing else (`skipsAutomaticCheck`)
  LanguageGate.swift            text that isn't English (NLLanguageRecognizer, precision-first rules): not sent when "Skip text that isn't English" is on
  RewriteDetector.swift         rewrite detection (guards measured with `eval/rewrite_report.py`)
  SpellingVariant.swift         US/UK respelling pairs (never respell a correct word into the other variant)
  Licence.swift                 LicenceKey (clean pasted text, verify `MEBOKI-` key offline with Ed25519 via CryptoKit), LicenceInfo, LicenceError, LicenceText (all licence strings)
  RevokedList.swift             signed list of refunded key IDs: parse + verify, newest `issued` wins
  TrialClock.swift              7 active days (local `yyyy-MM-dd`), rollback-proof, merge of two stores
  LicenceNotice.swift           `LicenceNotices`: which one-time notice is due (trial ended, key revoked / expired, last-day toast) from the entitlement, the flags and onboarding state
  UpdateRules.swift             `UpdateFeed` (a valid feed address + public key), `UpdateTiming` (when an automatic install may run), `UpdateNudge` (popup badge: pill, banner from day 7, version order), `UpdateText` (all update strings)
  Entitlement.swift             licensed / trial / free from key + revoked list + trial; Feature; effective settings in free mode (level, app mode, casual, automatic check)
Packages/Core/Tests/            Swift Testing suites
App/Info.plist                  bundle ID com.meboki.app, LSUIElement, CFBundleIconFile AppIcon
App/Art/                        icon and DMG background sources (SVG) and rendered files
Scripts/build-llama-server.sh   static Metal llama-server (llama.cpp, no OpenSSL) → Vendor/bin/
Scripts/make-app.sh             build + bundle (llama-server, Sparkle.framework) + sign inside out (Developer ID with hardened runtime + timestamp when the keychain has one, else Local Code Signing) → build/Meboki.app; --install → ~/Applications; `MEBOKI_FEED_URL` + `MEBOKI_UPDATE_KEY` turn the updater on
Scripts/make-art.sh             renders App/Art/AppIcon.svg → AppIcon.icns and dmg-background.svg → .tiff (1x + 2x); outputs committed, needs rsvg-convert
Scripts/make-dmg.sh             styled DMG (background, app left, Applications right, no toolbar) via dmgbuild in build/.dmg-venv; no Finder scripting
Scripts/test-update.sh          local updater test: old build + newer build signed with a throwaway key + a feed on 127.0.0.1:8765 (build/update-test/)
Scripts/release.sh              official release: Developer ID build with the updater, notarized + stapled app and DMG, signed appcast.xml; --publish creates the GitHub release (docs/releasing.md)
eval/                           Python benchmark (stdlib only) + results; eval/filter = Swift tool that scores the settings with Core; eval/runner = `meboki-eval-run` (Apple's model or llama-server, timed, for the bench kit)
Scripts/make-bench-kit.sh       bench kit for a macOS 26 Mac without Xcode or Python (runner + cases + Scripts/bench-kit/run-apple.sh, run-gemma.sh) → build/meboki-bench-kit.zip
docs/bench/                     long-field benchmark page
```

Flow: hotkey → `AX.snapshot` (focused element, `AX.text`, `AX.selection`) → `ProofreadEngine.check` (one request per paragraph) → `PostFilter.judge` → `Diff.edits` → `EditFilter` (settings) → `FixList` in `Session` → `AX.lineRects` (`AX.bounds`: native, markers or leaves) → underline overlay → click → glass card → `AX.replace` per fix.

Runtime paths: models in `~/Library/Application Support/Meboki/Models/`, logs in `~/Library/Logs/Meboki/` (`meboki.log`, `llama-server.log`; written only with Settings › Privacy › Logs on).

## Commands

DEBUG demo flags (own defaults suite and demo Keychain service, never the real state): `--settings-demo <pane> [--dark] [--licence-state trial|trialFresh|lastDay|free|licensed|revoked]`, `--onboarding-demo <step> [--trusted] [--no-model] [--licence-state …]`, `--popover-demo [--licence-state …] [--dark]`; each takes `--apple-model <state>` and `--use-apple` for Apple's built-in model, `--trial-ended-demo [--revoked|--expired] [--dark]`. With `MEBOKI_DEMO_SNAPSHOT=<file.png>` the onboarding, popover and notice demos draw their window into that file and quit (works with the screen locked).

```sh
swift build                                   # app + core
swift test                                    # core unit tests
MEBOKI_SERVER=http://127.0.0.1:PORT swift test   # + live test against a running llama-server
Scripts/build-llama-server.sh                 # once, or when bumping LLAMA_TAG
Scripts/make-app.sh --install                 # build, sign, install, launch
Scripts/release.sh 1.0.1 2 --publish          # notarized DMG + appcast → GitHub release (clean tree needed)
python3 eval/bench_ls.py eval/results_text <label> <model.gguf>   # benchmark a GGUF (see eval/README.md)
python3 eval/guard.py eval/results_text       # scores after post-filters
python3 eval/false_fixes_report.py            # known wrong suggestions stay fixed (no model); add a line per new one
python3 eval/settings_report.py eval/results_settings   # settings (US/UK, level, casual, protect) via Core
python3 eval/language_report.py               # language gate: English never left out, foreign left out (no model)
python3 eval/code_report.py                   # code detector: prose never taken for code, no block outside fences, source files are code with no residual prose, mixed cases (no model)
MEBOKI_PROSE_DIRS=<dir> python3 eval/code_report.py   # same, plus every .md under <dir> as extra prose
```

Run `swift build` and `swift test` after every change. For app changes, also run `Scripts/make-app.sh --install` and check the real app.

## Rules and invariants

- **Eval gate:** any change to the prompt, post-filters, or model files needs an `eval/` run. Compare with `eval/results_text/` and record the numbers with the change. `eval/false_fixes_report.py` must stay all ok; every wrong suggestion found gets a line in `eval/false_fixes.jsonl`.
- **Keep `Prompt.system` byte-identical** across requests. llama-server reuses its cached prefix, so only the user text is processed. Per-user settings (US/UK) go in once per session, never per request (`Prompt.system(for:)`). Per-app settings (Casual), the check level and protected tokens are post-filters (`EditFilter`), never prompt text.
- **All ranges are UTF-16 `NSRange`**, because the Accessibility API uses UTF-16. Emoji break anything else.
- **Never write text you haven't verified.** `AX.replace` checks the original is still at the range before writing, proves the selection (`AX.select(el, range, in:)`: the selected text must be the original; Chrome's selection read-back lies), and checks the prefix after. The paste fallback runs only when the field is unchanged, still focused, and its app is frontmost. Truncated or too-different model replies are rejected. Don't weaken these checks.
- **Privacy:** never read `AXSecureTextField` fields or anything while `IsSecureEventInputEnabled()`. No telemetry. Logs are off by default (`logEnabled`; `Log.write` and the `llama-server` output check it); when on they stay local, and text snippets are a second switch, also off by default (`Log.snippet`, `Log.pair`).
- **Cloud (BYOK):** nothing is sent until the user presses Use. API keys live only in the Keychain (`APIKeyStore`), never in UserDefaults, logs or toasts. Keep `store: false` on every Responses request and `provider.zdr: true` on OpenRouter; add only ZDR-capable models to the OpenRouter catalog.
- **Signing:** `make-app.sh` signs with the keychain's Developer ID Application identity (hardened runtime + secure timestamp) when there is one, else with `Local Code Signing` (docs/self-signed-certificate.md). Keep one identity per Mac: switching, or ad-hoc (`-`), resets the Accessibility permission. The bundle ID is `com.meboki.app` and never changes once released (Sparkle refuses an update with another ID; it also resets Accessibility). `LegacyMigration` moves what older bundle IDs left.
- **Updates:** never start Sparkle in a build without a feed, and never let a found version open a window or take the keyboard while another app is in use (`UpdateController`). System profiling stays off. The update signing key is never in the repository; `test-update.sh` makes a throwaway one under `build/`.
- **Model weights are never committed or bundled.** They're downloaded at runtime from pinned Hugging Face commits with SHA256. `*.gguf`, `Vendor/`, `.deps/` and `build/` are gitignored.
- `llama-server` must link only system libraries. `build-llama-server.sh` checks this, so keep `-DLLAMA_OPENSSL=OFF`.
- The core package must stay free of AppKit, so it can be reused (Windows, a CLI, tests).
- Swift 6 toolchain in Swift 5 language mode (`swiftLanguageModes: [.v5]`). App types that touch UI are `@MainActor`.
- This repository is public source: keep private plans, pricing, licensing and business notes out of it (code, comments, commit messages, docs).

## Testing in real apps

- **Never send blind keystrokes** (⌘W, Return, ⌘A/⌘C) through System Events. Send a keystroke only after checking that the front app is the expected one, and abort otherwise. Don't re-activate the target app while the panel should have focus.
- Read results through the app's AppleScript dictionary (for example `text of document 1` in TextEdit) or Accessibility, not through the clipboard.
- Close test tabs and documents by URL or name (`close (every tab … whose URL contains …)`), never with keystrokes.
- **Never test in Slack, Discord, Telegram, or Mail compose** by pressing Return; it sends the message. Ask a person to test those apps.
- Grammarly Desktop may be running. It captures Return and restarts through its `com.grammarly.ProjectLlama.Shepherd` launch agent. Ask before stopping it.

## Workflow

- Commit only when asked, directly to `master` (the only branch, never `main`). Don't create a feature branch unless the user explicitly asks.
- Before reporting work as done: build, test, and reinstall the app when app code changed.
