# Meboki

Local, private grammar checker for macOS. Press **⌃⌥G** in any text field: a local LLM (Gemma 4 via a bundled `llama-server`) proofreads the field (or just the selection), shows the changes, and **Apply** writes them back. Text never leaves the Mac.

Status: Milestone A (hotkey proofreading), plus Milestone B: with the local model, text areas are checked as you type, no hotkey needed.

## Requirements

- Apple Silicon Mac, macOS 14+
- Xcode 26 (selected with `xcode-select`), CMake (`brew install cmake`)
- A code-signing identity named `Local Code Signing` in the login keychain (see [Signing certificate](#signing-certificate)). Override with `SIGN_IDENTITY=…`.
- ~5 GB disk for the model (downloaded on first launch)

## Build and run

```sh
Scripts/build-llama-server.sh      # once: static Metal llama-server → Vendor/bin/ (~2 min)
Scripts/make-app.sh --install      # build, sign, copy to ~/Applications, open
```

On first launch the **Welcome** window walks you through setup (open it again any time: right-click the menu-bar icon › Welcome Guide…, or Settings › About):
1. **Accessibility:** Open System Settings, turn on Meboki in Privacy & Security → Accessibility; the window notices the grant by itself. Because every build is signed with the same certificate, the grant survives rebuilds.
2. **Model:** download the recommended model (Gemma 4 E4B on 16 GB+ Macs, E2B on 8 GB) from Hugging Face into `~/Library/Application Support/Meboki/Models`. Nothing downloads until you press Download; you can go on while it downloads.
3. **Try it:** check a sample sentence in the window, or open a practice note in TextEdit and press ⌃⌥G there.
4. When the menu says **Ready**, click into a text field and press **⌃⌥G**. The mistakes get wavy underlines in the field. Click one to open its card: ⏎ applies all fixes, ⇧⏎ applies this one, ⇥ ignores it, ← → move between fixes, Esc closes the card. Esc with no card open or switching away clears the underlines. When the whole field was checked with the local model, typing keeps the review: the underlines follow the text, fixes in the sentence you edit go away, and that sentence is checked again when you pause (Settings › General › Underline mistakes as I type; with a selection or a cloud model, typing clears the underlines). With Settings › General › Underline mistakes as I type on (the default) and the local model, you don't need ⌃⌥G at all: when you pause in a text area (or click into one that holds text), Meboki checks what's on screen and underlines the mistakes. Esc hides them until you leave the field; ignored fixes stay ignored. Single-line fields (URL bars, search boxes), terminals and code editors, fields in paused or Off apps, and apps that don't report where words are on screen aren't checked automatically; ⌃⌥G still works there. Apps that don't report where words are on screen (some web and Electron fields) skip the underlines: the card opens below the field right away and steps through the fixes. Settings › General switches between the glass card, the anchored bubble (a small card pointing at the word) and the island HUD. The island is a dark capsule under the menu bar: it appears while checking, then shows the current fix and takes the keys right away (⏎ all, ⇧⏎ this one and the next, ⇥ skip, ← →, Esc ends); hover it for the reason and the next fixes; clicking an underline makes that fix current; typing still goes to your app. Settings › Writing › Explain each fix hides or shows the reason line.

Menu bar: a click on the icon opens the popover: status, **Check focused field**, **Pause in {App}** (⌃⌥G does nothing there until you turn it back on), English US/UK and check level, and the model in use. The gear (or ⌘,) opens Settings: popup style, launch at login, show in menu bar, the check shortcut (click the field and press a new one with ⌃, ⌥ or ⌘), models (download, pause, resume, switch), per-app On / Casual / Off, and log snippets. While Settings is open Meboki shows a Dock icon. With the menu-bar icon hidden, open Meboki again from Finder to get to Settings. Settings › Writing: English variant (US or UK prompt; a correct word is never respelled into the other variant), Check for (Spelling, Grammar, Full), Casual mode in chat apps (keeps lowercase starts and missing periods; also per app in Settings › Apps) and Protect names, code and links (edits touching URLs, @mentions, `code`, paths or identifiers are dropped). Settings › Models › **Cloud · your own API key** (optional): pick OpenRouter or OpenAI, paste a key (stored in your login Keychain), pick a model, press **Test**, then **Use**. Checks then go to that provider (OpenRouter: zero-data-retention hosts only; OpenAI: storage off) and the local model is stopped; pick a local model to switch back. The popover and the card show a cloud symbol while cloud is in use. A right-click opens the debug menu: Settings, models folder, logs (`~/Library/Logs/Meboki/llama-server.log`).

## Signing certificate

Local builds need no Developer ID, notarization or DMG: apps built on the same Mac aren't quarantined. They do need a
**stable signing identity**, so the Accessibility grant survives rebuilds. `Scripts/make-app.sh` signs the app and the
bundled `llama-server` with a self-signed code-signing certificate named `Local Code Signing` in the login keychain.
Create it once (Keychain Access › Certificate Assistant › Create a Certificate, Self-Signed Root, type Code Signing,
does the same):

```sh
cat > cs.cnf <<'EOF2'
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = Local Code Signing
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF2
# /usr/bin/openssl (LibreSSL) writes a .p12 that `security import` accepts
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cs.cnf
P=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "Local Code Signing" -out cs.p12 -passout pass:$P
security import cs.p12 -k ~/Library/Keychains/login.keychain-db -P "$P" -T /usr/bin/codesign -T /usr/bin/security
rm -f key.pem cs.p12   # the private key now lives only in the keychain
```

`security find-identity -p codesigning` shows it as `CSSMERR_TP_NOT_TRUSTED`; that's expected for a self-signed
certificate. Signing with another identity (ad-hoc `-`, a new certificate, a team certificate) means granting
Accessibility again in System Settings. Remove it with `security delete-identity -c "Local Code Signing"`.

## Development

```sh
swift build                         # app + core
swift test                          # core unit tests (prompt, post-filters, diff)
MEBOKI_SERVER=http://127.0.0.1:8080 swift test   # + live test against a running llama-server
.build/debug/Meboki --gallery  # debug builds only: design component gallery, light + dark
.build/debug/Meboki --demo-popups --all   # debug: card, toast, bubble and island with sample content
.build/debug/Meboki --contrast-probe      # debug: glass over black/white/grey backdrops, for contrast checks
```

Debug builds also take `--increase-contrast`, `--reduce-motion` and `--differentiate-without-color` (with the modes
above, or with `--settings-demo <pane>`) to show those accessibility variants without changing System Settings.

Layout:
- `Packages/Core` — `MebokiCore`: prompt, local and cloud (Responses API) clients, post-filters, word diff. No AppKit.
- `App/Sources/Meboki` — menu-bar app: Accessibility read/write, hotkey, underline overlay, glass card and toasts, model download, llama-server process.
- `App/Sources/Meboki/Design` — design tokens and shared UI components.
- `eval/` — model/prompt benchmark. Run it before changing the prompt, filters, or model files.

## Known limits (Milestone A)

- Works where the app exposes the field's text through Accessibility: native apps, Safari, Chrome, most Electron apps. Not Google Docs or other canvas editors.
- Rich web editors: Chrome and Electron `contenteditable` fields (x.com, Gmail, Notion, Slack, Obsidian) get underlines through their text leaves, and Mail compose is read and written through WebKit text markers (Apply selects the word and pastes). Hand-tested in all of them (2026-11-16). In a Mail reply, ⌃⌥G also checks the quoted text.
- Password fields and Secure Input are never read.
- If an app ignores Accessibility writes, Apply falls back to select + paste (the clipboard is restored afterwards).
- VoiceOver: popups announce the fix they show ("Spelling: tomorow to tomorrow. 1 of 6.") and every button names its
  key ("Apply all 6 fixes, Return"). Reduce Motion, Increase Contrast, Reduce Transparency and Differentiate Without
  Color are followed. Not yet tried with VoiceOver running.
- Grammarly Desktop running at the same time can capture the Return key, so Return may not reach the card. Click **Apply all** instead, or pause Grammarly.

Tested end-to-end (2026-11-15): TextEdit, Chrome `<textarea>`, Safari `<textarea>`.
