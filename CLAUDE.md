# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**Meboki** is an open-source (GPL-3.0), local, Grammarly-like grammar checker for macOS. It checks English text in any app's text field with a local open-source LLM. Text never leaves the Mac.

- **Today (Milestone A + UI redesign stage 9):** a menu-bar app. **⌃⌥G** proofreads the focused field, or the selection if there is one. The mistakes get wavy underlines in the field; a click on one opens a glass card under that word: **⏎** applies all fixes, **⇧⏎** applies this one, **⇥** ignores it, **← →** move between fixes, **Esc** closes the card. Esc with no card or leaving the field clears the underlines; typing does too, except in a live review (Milestone B step 2: whole field, local model, "Underline mistakes as I type" on), where the fixes follow the text and the edited sentences are re-checked after a pause through `CheckScheduler`. With that setting on and the local model, no hotkey is needed (Milestone B step 3, `FocusTracker`): the focused editable text area is checked after a typing pause (or on focus), and fixes show as underlines only (an automatic review; Esc mutes the field until focus moves; ignored fixes stay ignored). Apps that give no text bounds get the card below the field instead. The popup can be the glass card, the anchored bubble, or the island HUD (Settings › General). The island is a dark capsule under the menu bar that shows checking, the current fix (it takes ⏎ ⇧⏎ ⇥ ← → Esc and passes other keys to the app), the done line and messages. In card and bubble style, messages and the done line are glass toasts. A left-click on the menu-bar icon opens the popover (status, Check focused field, Pause in {App}, English, Check level, model row); a right-click opens the debug menu. The Settings window (⌘, or the popover gear) has General (popup style, launch at login, show in menu bar, shortcut recorder), Writing, Models (download, pause, resume, SHA-256 check, use; plus BYOK cloud: OpenRouter or OpenAI key in the Keychain, model, Test, Use), Apps (On / Casual / Manual / Off per app; a built-in skip list: terminals and code editors Manual, password managers and remote desktops Off, `AppRules`; a field that looks like code gets no automatic check, `CodeDetector`), Shortcuts, Privacy (log snippets switch) and About. Writing's English variant picks the prompt (US or UK, fixed per session); Check for, Casual mode (chat apps, or an app set to Casual) and Protect names/code/links are post-filters on the model's reply. Skip text that isn't English (off by default, `LanguageGate`) keeps foreign paragraphs and sentences from the model.
- **Cloud (BYOK, opt-in):** with a key saved and **Use** pressed, checks go to OpenRouter or OpenAI through the Responses API (`ResponsesClient`) and `llama-server` stops. Text then leaves the Mac; the UI says so (cloud symbol, provider name). Local stays the default.
- **Text-marker adapter (Milestone B step 4):** Chromium `contenteditable` (x.com, Gmail, Notion, Slack, Obsidian) gets underlines through its static-text leaves; Mail compose (a WebKit editable `AXWebArea`) is read, selected and measured through text markers and written by select + paste. Read field text, selection and bounds through `AX.text` / `AX.selection` / `AX.select` / `AX.bounds(el, range, text:)`, never `kAXValueAttribute` directly.
- **Performance work done:** long fields (grouped Apply all, `KeyGuard` holds ⏎ during an apply, leaf-based visible range for Chromium, `llama-server -np 4 --kv-unified` + pipeline lookahead, in-place leaf map; on the 300-fix benchmark page `docs/bench/long-field-300-fixes.html`: first check ~50 s → ~4 s, Apply all 102 s → 28 s) and idle unload (`ServerManager`: Settings › Models › Unload when idle, memory pressure, reload on the next check).
- **Onboarding:** the first launch opens a Welcome window: Accessibility with a live-detected grant, model download (nothing downloads until the user presses Download; no launch starts a download), a sample check, final switches. Reopen: right-click menu › Welcome Guide…, Settings › About.
- **Licence (stage A2):** a 7-day trial, then a free mode (hotkey check only; the Stays-free list is untouched). `LicenceManager` joins the stored key, the revoked list and the trial clock into an `Entitlement`; `AppSettings` keeps the stored values and exposes `effective…` ones (`effectivePopupStyle`, `effectiveCheckLevel`, `effectiveCasualMode`, `effectiveUnderlineAsYouType`, `effectiveAppMode(_:)`), which the check flow must read instead of the stored ones. `meboki://activate?key=…` activates a key (`AppDelegate.handleActivationURL`) and shows the result in Settings › Licence (`AppDelegate.showLicence()` opens that pane). In free mode Settings keeps the stored values, dimmed with a lock; a click on a locked control opens a "Needs a licence" popover. Nothing is sent but a daily GET of the public revoked list, and only with a licence installed. **Where the user meets it (stage A4):** the onboarding Done page has a licence card (trial, free or licensed; in free mode the underline switch and the bubble / island choices on the Popup page are locked); once, when the app first finds itself in free mode, the Trial ended window opens (`TrialEndedWindowController`, brought to the front with `orderFrontRegardless`, never activated, so the keyboard stays in the app being typed in); a refunded, cancelled or expired key gets the same window with other wording, once per key; on the last trial day, after its first check, one toast "Last day of the full trial" (waits while a check runs or a popup is on screen). The popover shows "Trial · N days left" (opens Settings › Licence), or in free mode "Free mode · checks only on ⌃⌥G" with Unlock and the Underline tile and Check level locked. Which notice is due is a pure function in Core (`LicenceNotices`); `AppDelegate.showDueLicenceNotices` calls it at launch (after onboarding), on every entitlement or trial-clock change and when onboarding closes. Nothing else nags. **Details (review fixes):** a trial day is stored as the real day, so a clock that jumped forward once doesn't freeze the count (the latest day seen is used only to end the trial); day strings always use a Gregorian calendar (`Calendar.licenceDays`); the Keychain is touched only on `TrialStore.queue`, and demo managers never touch it; the revoked list is stored only after a verified 200 response (a failed download is retried after 10 minutes, at most 1 MB is read) and kept when the key is removed; a `meboki://activate` link never replaces a different working key (Settings › Licence opens with the key in the field, press Activate), and a link that opens the app waits until launch is done (during onboarding it activates silently); the automatic check counts a trial day only when it really asked the model; a review whose popup style no longer matches the effective one ends when the entitlement changes.
- **Updates:** Sparkle 2 (SwiftPM), wrapped by `UpdateController`. Only a build whose Info.plist has `SUFeedURL` and `SUPublicEDKey` has an updater (`make-app.sh` adds them from `MEBOKI_FEED_URL` / `MEBOKI_UPDATE_KEY`); a plain build never starts Sparkle and hides every update row. One check a day (on by default, nothing about the user is sent), automatic install off by default. A version found by the daily check never opens a window over the app being typed in: a green dot on the menu-bar icon and a popover row, and Sparkle's window on request (popover row, Settings › General or About, right-click › Check for Updates…). With automatic install on, the downloaded update goes in when the app quits or at a quiet moment (`UpdateTiming`: nothing of the app in use, no input for 2 minutes), and the app reopens without opening a window. `Scripts/test-update.sh` runs the whole thing locally.
- Target: Apple Silicon, macOS 14+. A Developer ID build notarizes cleanly; there's no public release, DMG or release script yet.

## Documents

| File | What it holds |
|---|---|
| [README.md](README.md) | Build, run and test instructions, the signing certificate, known limits. |
| [eval/README.md](eval/README.md) | Model and prompt benchmark: dataset, runners, reports. |
| `docs/bench/long-field-300-fixes.html` | Benchmark page for long fields (Chrome `contenteditable`, 12 009 characters, 300 fixes). Also read by `eval/bench_parallel.py`, `eval/language_report.py` and `eval/code_report.py`. |

Code comments cite design and plan sections (`PLAN.md §…`, `design_code.md §…`). Those documents are not in this repository.

## Architecture

```
App/Sources/Meboki/             menu-bar app (AppKit + SwiftUI), target "Meboki"
  AppDelegate.swift             debug menu, popover state, hotkey, check flow, pause gate, review session on a FixList (underlines or fallback card, apply / apply all / ignore), toasts, status pulse
  Accessibility.swift           AX read/write, app quirks, secure-input checks, paste fallback, ClipboardGuard, Log
  RichText.swift                text-marker adapter: AX.text / selection / select / bounds for any field (Chromium contenteditable via text leaves, WebKit editable web areas like Mail via text markers)
  FieldProbe.swift              DEBUG `--probe-field <bundle id> [word …]`: what the adapter sees in an app's focused field
  Flow/Panels.swift             KeyPanel, HostedPanel (transparent non-activating panel, sync sizing), placement below the field
  Flow/Panels.swift             (also) PopupKeys: the shared popup keys ⏎ ⇧⏎ ⇥ ← → Esc
  Flow/GlassCardView.swift      glass card view + CardPanel (under a word, or below the field in the fallback)
  Flow/BubbleView.swift         anchored bubble view + BubblePanel (tip points at the word)
  Flow/PopupController.swift    picks card or bubble from AppSettings.popupStyle
  Flow/IslandView.swift         island HUD view + IslandPanel (style `island`: checking, review, done, messages)
  Onboarding/OnboardingWindow.swift   onboarding window (680 × 560), OnboardingModel (step, trust, engine, try state), AppMenus (window menu, accessory policy on close)
  Onboarding/OnboardingViews.swift    pages: Welcome, Accessibility (live grant), Model (download, disk space), Try it (sample check), Popup style (live preview), Done
  Onboarding/OnboardingDemo.swift     DEBUG `--onboarding-demo <step> [--dark] [--trusted] [--downloading]` for screenshots
  Settings/AppSettings.swift    UserDefaults-backed settings (popup style, writing options, appModes, checkedApps, hotkey, logSnippets, showInMenuBar, …)
  Licence/LicenceManager.swift  licence state (`entitlement`: licensed / trial / free), activation, `recordCheck` per real check, daily revoked-list fetch, `transitions`; Licence/LicenceStore (key + revoked list files), TrialStore (Keychain + UserDefaults), LicenceCLI (DEBUG `--licence-status`, `--verify-licence <key>`)
  Licence/LicenceDebug.swift    DEBUG: `DebugClock` (the licence manager's clock = real time + an offset kept in UserDefaults), `DebugSigner` (signs test keys and revoked lists with the test-payment key read from the login Keychain, `meboki` / `app-license-sandbox-private-key`)
  Settings/Panes/DebugPane.swift  DEBUG: Settings › Debug: live licence status; trial presets (past days, last day, end), clock jumps (23:59:50, +1 h, +1 day, real time), onboarding reset (+ open), test keys (activate, corporate ending tomorrow, copy, activation link), revoke / clear / fetch the revoked list. Build with `Scripts/make-app.sh --debug --install`
  Licence/TrialEndedWindow.swift  the one-time notice window (trial ended / key no longer valid), `TrialEndedView`, `TrialEndedWindowController` (shown without activating)
  Licence/LicenceDemo.swift     DEBUG demos: `LicenceDemo` (own manager forced into a state), `TrialEndedDemo`, `PopoverDemo`, `DemoSnapshot`
  Settings/APIKeyStore.swift    BYOK API keys in the login Keychain (one item per provider)
  Settings/Shortcut.swift       recorded global shortcut (key code, Carbon modifiers, glyphs), macOS-shortcut conflict check
  Settings/SettingsWindow.swift Settings window (800 × 580, traffic lights in the glass sidebar, search, toast), SettingsModel, recorder key monitor
  Settings/SettingsComponents.swift  group, row, key field, footnote, app icon
  Settings/Panes/*.swift        General (style picker art, hotkey field), Writing, Models, Apps, Shortcuts, Privacy, Licence (status card, buy, key field, remove), About
  Settings/LicenceLock.swift    free-mode lock marks: `LicenceGate` (environment), `.licenceLocked(_:caption:)`, `NeedsLicencePopover`, `FreeModeBanner`; `DSSegmented(locked:onLockedTap:)`
  Settings/SettingsDemo.swift   (see also the DEBUG demo flags below) DEBUG `--settings-demo <pane> [--dark] [--recording] [--bubble] [--licence-state trial|trialFresh|lastDay|free|licensed|revoked]` for screenshots (own licence manager, temp folder, demo Keychain service)
  Updates/UpdateController.swift  Sparkle wrapper: on only with a feed in Info.plist, gentle reminder state (`available`, `needsAttention`), the two switches, install at a quiet moment; DEBUG `MEBOKI_DEMO_UPDATE=<version>` fakes a found version for the demo flags
  MenuBar/StatusItem.swift      status icon: left-click popover, right-click debug menu, icon states (checking, paused, update waiting, open)
  MenuBar/PopoverView.swift     menu-bar popover view + PopoverPanel (non-activating, under the icon): status, check button, tiles, model row
  Flow/UnderlineOverlay.swift   click-through overlay: wavy underlines, current/hover fill, applied flash, hit-test
  Flow/PopupPreview.swift       looping animated demo of a popup style (real card / bubble / island over a mini desktop): onboarding and Settings › General
  Flow/FocusTracker.swift       automatic check: follows the frontmost app's focused element (AXObserver focus + value)
  Flow/FieldWatcher.swift       review-session watcher: AXObserver (value, focus, move, scroll) + global monitors + tick
  Flow/ToastPanel.swift         glass toasts (done line, messages), auto-hide, Esc / click outside
  Flow/KeyGuard.swift           event tap (own thread) that holds ⏎ ⇥ arrows Esc while fixes are written; Esc stops Apply all
  Design/                       tokens, glass, shared components, DEBUG gallery
  ModelStore.swift              Catalog (pinned HF URLs + SHA256) and downloader (resume, checksum)
  ServerManager.swift           bundled llama-server child process (127.0.0.1, random port, /health)
  HotKey.swift                  Carbon RegisterEventHotKey
  LegacyMigration.swift         one-time move of settings (dev.local.meboki, dev.local.proofreader) and of models, logs from pre-rename builds
Packages/Core/Sources/MebokiCore/        pure Swift, no AppKit, unit-tested
  Prompt.swift                  the benchmarked few-shot system prompt
  LLMClient.swift               `Corrector` protocol; OpenAI-compatible chat client for llama-server; detects truncated replies
  ResponsesClient.swift         BYOK cloud: OpenAI Responses API with SSE streaming (OpenAI, OpenRouter), store off, ZDR on OpenRouter
  CloudCatalog.swift            CloudProvider (base URL, key shape) and the cloud models (reasoning/temperature settings, benchmark)
  PostFilter.swift              clean wrappers, similarity guard (Ratcliff/Obershelp = difflib), style-only filter
  Diff.swift                    word-level diff → UTF-16 `Edit`s
  ProofreadEngine.swift         ProofreadEngine: paragraph chunks → model → filters → edits
  CheckPipeline.swift           Milestone B: sentence cache (only changed sentence runs go to the model), cursor-first order, scope; CheckScheduler (typing pause, stale-pass cancel)
  FixList.swift                 fixes in any order (UTF-16 range shifting), n of N, card swap text and underline range (FixDisplay); live review: textEdited, reconcile; Apply all groups (one write per paragraph run)
  IgnoredFixes.swift            fixes the user ignored, by sentence, so later checks leave them out
  TextChange.swift              one contiguous change between two field values (common prefix/suffix, surrogate-safe)
  TextLeafMap.swift             lines up a rich editor's static-text leaves with its AXValue (UTF-16), splits ranges into leaf-local pieces
  FixCategory.swift             diff classifier (spelling / grammar / clarity / punctuation) + reason templates
  CheckOptions.swift            EnglishVariant, CheckLevel, CheckOptions (the settings a check uses)
  EditFilter.swift              settings post-filters on edits: casual text, slang, UK collective nouns, check level
  ProtectedTokens.swift         URLs, emails, @mentions, #tags, code, paths, identifiers, emoji, non-Latin words
  AppRules.swift                AppMode (on / casual / manual / off), the built-in skip list (terminals and code editors, password managers, remote desktops) with default modes, chat apps; CodeAppLearner (learned Manual: 3 code fields, no prose); the user's choice always wins
  CodeDetector.swift            a field that looks like code (precision-first line shapes): the automatic check skips it
  LanguageGate.swift            text that isn't English (NLLanguageRecognizer, precision-first rules): not sent when "Skip text that isn't English" is on
  RewriteDetector.swift         rewrite detection (guards measured with `eval/rewrite_report.py`)
  SpellingVariant.swift         US/UK respelling pairs (never respell a correct word into the other variant)
  Licence.swift                 LicenceKey (clean pasted text, verify `MEBOKI-` key offline with Ed25519 via CryptoKit), LicenceInfo, LicenceError, LicenceText (all licence strings)
  RevokedList.swift             signed list of refunded key IDs: parse + verify, newest `issued` wins
  TrialClock.swift              7 active days (local `yyyy-MM-dd`), rollback-proof, merge of two stores
  LicenceNotice.swift           `LicenceNotices`: which one-time notice is due (trial ended, key revoked / expired, last-day toast) from the entitlement, the flags and onboarding state
  UpdateRules.swift             `UpdateFeed` (a valid feed address + public key), `UpdateTiming` (when an automatic install may run), `UpdateText` (all update strings)
  Entitlement.swift             licensed / trial / free from key + revoked list + trial; Feature; effective settings in free mode (level, app mode, casual, automatic check)
Packages/Core/Tests/            Swift Testing suites
App/Info.plist                  bundle ID com.meboki.app, LSUIElement
Scripts/build-llama-server.sh   static Metal llama-server (llama.cpp, no OpenSSL) → Vendor/bin/
Scripts/make-app.sh             build + bundle (llama-server, Sparkle.framework) + sign inside out (Developer ID with hardened runtime + timestamp when the keychain has one, else Local Code Signing) → build/Meboki.app; --install → ~/Applications; `MEBOKI_FEED_URL` + `MEBOKI_UPDATE_KEY` turn the updater on
Scripts/test-update.sh          local updater test: old build + newer build signed with a throwaway key + a feed on 127.0.0.1:8765 (build/update-test/)
Scripts/release.sh              official release: Developer ID build with the updater (feed https://meboki.com/api/appcast.xml), notarized + stapled app and DMG, appcast.xml signed with the keychain update key (account meboki); --publish tags and creates the GitHub release (mebokihq/meboki)
eval/                           Python benchmark (stdlib only) + results; eval/filter = Swift tool that scores the settings with Core
docs/bench/                     long-field benchmark page
```

Flow: hotkey → `AX.snapshot` (focused element, `AX.text`, `AX.selection`) → `ProofreadEngine.check` (one request per paragraph) → `PostFilter.judge` → `Diff.edits` → `EditFilter` (settings) → `FixList` in `Session` → `AX.lineRects` (`AX.bounds`: native, markers or leaves) → underline overlay → click → glass card → `AX.replace` per fix.

Runtime paths: models in `~/Library/Application Support/Meboki/Models/`, logs in `~/Library/Logs/Meboki/` (`meboki.log`, `llama-server.log`).

## Commands

DEBUG demo flags (own defaults suite and demo Keychain service, never the real state): `--settings-demo <pane> [--dark] [--licence-state trial|trialFresh|lastDay|free|licensed|revoked]`, `--onboarding-demo <step> [--trusted] [--no-model] [--licence-state …]`, `--popover-demo [--licence-state …] [--dark]`, `--trial-ended-demo [--revoked|--expired] [--dark]`. With `MEBOKI_DEMO_SNAPSHOT=<file.png>` the onboarding, popover and notice demos draw their window into that file and quit (works with the screen locked).

```sh
swift build                                   # app + core
swift test                                    # core unit tests
MEBOKI_SERVER=http://127.0.0.1:PORT swift test   # + live test against a running llama-server
Scripts/build-llama-server.sh                 # once, or when bumping LLAMA_TAG
Scripts/make-app.sh --install                 # build, sign, install, launch
Scripts/release.sh 1.0.1 2 --publish          # notarized DMG + appcast → GitHub release (clean tree needed)
python3 eval/bench_ls.py eval/results_text <label> <model.gguf>   # benchmark a GGUF (see eval/README.md)
python3 eval/guard.py eval/results_text       # scores after post-filters
python3 eval/settings_report.py eval/results_settings   # settings (US/UK, level, casual, protect) via Core
python3 eval/language_report.py               # language gate: English never left out, foreign left out (no model)
python3 eval/code_report.py                   # code detector: prose never taken for code, source files are (no model)
MEBOKI_PROSE_DIRS=<dir> python3 eval/code_report.py   # same, plus every .md under <dir> as extra prose
```

Run `swift build` and `swift test` after every change. For app changes, also run `Scripts/make-app.sh --install` and check the real app.

## Rules and invariants

- **Eval gate:** any change to the prompt, post-filters, or model files needs an `eval/` run. Compare with `eval/results_text/` and record the numbers with the change.
- **Keep `Prompt.system` byte-identical** across requests. llama-server reuses its cached prefix, so only the user text is processed. Per-user settings (US/UK) go in once per session, never per request (`Prompt.system(for:)`). Per-app settings (Casual), the check level and protected tokens are post-filters (`EditFilter`), never prompt text.
- **All ranges are UTF-16 `NSRange`**, because the Accessibility API uses UTF-16. Emoji break anything else.
- **Never write text you haven't verified.** `AX.replace` checks the original is still at the range before writing, proves the selection (`AX.select(el, range, in:)`: the selected text must be the original; Chrome's selection read-back lies), and checks the prefix after. The paste fallback runs only when the field is unchanged, still focused, and its app is frontmost. Truncated or too-different model replies are rejected. Don't weaken these checks.
- **Privacy:** never read `AXSecureTextField` fields or anything while `IsSecureEventInputEnabled()`. No telemetry. Logs stay local, with short snippets only (`Log.snippet`).
- **Cloud (BYOK):** nothing is sent until the user presses Use. API keys live only in the Keychain (`APIKeyStore`), never in UserDefaults, logs or toasts. Keep `store: false` on every Responses request and `provider.zdr: true` on OpenRouter; add only ZDR-capable models to the OpenRouter catalog.
- **Signing:** `make-app.sh` signs with the keychain's Developer ID Application identity (hardened runtime + secure timestamp) when there is one, else with `Local Code Signing` (README › Signing certificate). Keep one identity per Mac: switching, or ad-hoc (`-`), resets the Accessibility permission. The bundle ID is `com.meboki.app` and never changes once released (Sparkle refuses an update with another ID; it also resets Accessibility). `LegacyMigration` moves what older bundle IDs left.
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
