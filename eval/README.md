# eval — grammar-correction benchmark

Gate for any prompt, model, or post-filter change. Python 3, stdlib only.

## Files

| File | Purpose |
|---|---|
| `dataset.py` | 80 test cases: `ERR` (45 with errors), `OK` (22 correct, must stay unchanged), `CASUAL` (6 chat lines), `EDGE` (7 tricky: non-English, injection, questions), `PARAGRAPH` (5 sentences, 7 errors). Stage 9 settings sets (42 more, scored separately): `UK_OK` (8), `UK_ERR` (6), `CHAT` (8), `CHAT_ERR` (6), `LEVEL` (7, expected output per check level), `PROTECT` (7). Language gate sets (no model, `language_report.py`): `LANG_FOREIGN` (14), `LANG_SHORT` (6), `LANG_MIXED` (4), `LANG_ENGLISH` (12) |
| `bench.py` | Core runner + prompts (`basic`, `fewshot`, `fewshot-uk` = `Prompt.systemUK`). Default backend: Ollama (`localhost:11434`). `BENCH_SETTINGS=0` skips the stage 9 sets |
| `bench_ls.py` | Same benchmark against a text-only GGUF via `llama-server` (OpenAI-compatible API); records peak RSS |
| `bench_or.py` | Same benchmark against cloud models via OpenRouter; records billed cost |
| `bench_parallel.py` | Parallel requests (Optimization A3): starts `llama-server` with `-np N --kv-unified` the way the app does, times the long-field page's paragraphs (`docs/bench/long-field-300-fixes.html`) one at a time and N at a time, then runs every benchmark case N at a time (same JSON as `bench_ls.py`) and lists replies that differ from the sequential run (label without `-npN`). `BENCH_KVU=0 BENCH_CTX=16384` tries separate per-slot KV |
| `guard.py` | Applies the post-filters (similarity < 0.75 → drop, style-only change → drop) and reports raw → guarded scores |
| `code_report.py` | Code detector (no automatic check in a field that looks like code): every benchmark input, `LANG_ENGLISH`, the repo's Markdown docs (whole and per section, fenced code removed) and the long-field page must stay prose; the 67 adversarial prose cases in `code_cases.json` must stay prose too; the repo's source files (Swift, Python, shell, JSON, plist, HTML) must count as code. Via `filter/ --code` (`CodeDetector.verdict`). No model needed. Reports 20-line snippets too (not scored) |
| `language_report.py` | Language gate (Settings › Writing › "Skip text that isn't English"): runs every benchmark input, `LANG_ENGLISH`, the repo's docs and the long-field page (must stay fully English), `LANG_FOREIGN` (fully left out) and `LANG_MIXED` (exactly the foreign sentences) through `LanguageGate` via `filter/ --language`. No model needed. `-v` lists `LANG_SHORT` |
| `rewrite_cases.py`, `rewrite_run.py`, `rewrite_report.py` | Rewrite detection (`RewriteDetector`): 62 extra inputs (local fixes, awkward, harsh), replies recorded from the running llama-server into `results_rewrite_e4b.json`, then scored through Core (`filter/ --rewrite`) together with the benchmark's replies. `-v` lists rewrites, `-t` the ratio table |
| `settings_report.py` | Scores the settings (US/UK, check level, casual, protect) on a `fewshot` + `fewshot-uk` run, through the app's Core code: each reply goes through `ProofreadEngine.process` in the Swift tool `filter/` (`meboki-eval-filter`, built by the script). Also checks that `bench.py`'s prompts are byte-identical to `Prompt.swift` |
| `filter/` | That Swift tool (an executable target in `Package.swift`, not part of the app) |
| `runner/` | `meboki-eval-run` (executable target, not part of the app): runs cases through Apple's on-device model (`--apple`, `AppleModelClient`) or llama-server (`--server URL`, the app's `LLMClient`) and times each reply (wall, time to first token with `--stream`, cold and warm first call, `--lanes N` in flight); writes JSON lines with the Mac's chip, RAM and macOS build. `--probe` prints the Mac's facts and whether Apple's model is available (exit 3 if not). Needs no Xcode or Python on the Mac it runs on |
| `export_cases.py` | Writes `cases.jsonl` (every `bench.py` case with a stable id, settings sets and the paragraph) and `page.jsonl` (the long-field page's paragraphs) for the runner |
| `bench_remote.py` | Turns a bench kit's returned `results/` into standard result JSONs in `results_apple/` (`<label>-<macOS build>__fewshot[-uk].json`), prints the speed table (sentence p50/p90, paragraph, first token, cold/warm, 1/2/4 lanes and how many replies differ, long-field page), then runs `report.py`, `guard.py` and `settings_report.py` |
| `results_apple/` | Apple Intelligence runs and the same-Mac Gemma comparison (none yet) |
| `report.py` | Prints summary per results file; optional model substrings dump mismatches |
| `cloud_report.py` | Cost table for cloud results (prices from `or_models.json`, an OpenRouter `/models` snapshot from 2026-11-14) |
| `results/` | Ollama runs, 2026-11-13 (`<model>__<prompt>.json`) |
| `results_text/` | Text-only `llama-server` runs |
| `results_settings/` | Stage 9 runs, 2026-11-16: shipped Gemma 4 E4B / E2B Q4_0 with `fewshot` and `fewshot-uk`, all 122 cases; catalog Qwen3.5 4B / Llama 3.1 8B Q4_K_M, same prompts |
| `results_parallel/` | Parallel-slot runs, 2026-11-16: shipped Gemma 4 E4B Q4_0, `fewshot`, 1 / 2 / 4 / 8 slots |
| `results_cloud/` | OpenRouter runs, 2026-11-14 |

## Usage

```sh
# Local via Ollama
python3 bench.py results fewshot gemma4:e4b qwen3.5:4b

# Local text-only GGUF via llama-server (default binary: the one bundled in Ollama.app)
LLAMA_SERVER=/path/to/llama-server python3 bench_ls.py results_text gemma4-e4b-text ~/models/gemma-4-E4B-it-Q4_K_M.gguf

# Cloud via OpenRouter (key read from macOS Keychain, service name OPENROUTER_API_KEY)
python3 bench_or.py results_cloud anthropic/claude-haiku-5.5

# Reports
python3 report.py results_text            # raw scores
python3 report.py results_text gemma4     # + mismatches for matching models
python3 guard.py results_text             # scores after post-filters
# Settings (stage 9): record both prompts, then score every setting through Core
LLAMA_SERVER=../Vendor/bin/llama-server python3 bench_ls.py results_settings gemma4-e4b-q4_0-text \
    ~/Library/Application\ Support/Meboki/Models/gemma-4-E4B-it-Q4_0.gguf fewshot,fewshot-uk
python3 settings_report.py results_settings          # add a model substring to list the misses
python3 cloud_report.py results_cloud     # cost per check / per user
# Parallel slots: sequential baseline first, then N slots (compared reply by reply)
python3 bench_parallel.py results_parallel e4b ~/Library/Application\ Support/Meboki/Models/gemma-4-E4B-it-Q4_0.gguf 1
python3 bench_parallel.py results_parallel e4b-np4 ~/Library/Application\ Support/Meboki/Models/gemma-4-E4B-it-Q4_0.gguf 4
```

Store the OpenRouter key once with:

```sh
security add-generic-password -s OPENROUTER_API_KEY -a "$USER" -w
```

## Apple Intelligence on another Mac

Apple's on-device model needs macOS 26 with Apple Intelligence on, so it is measured on a second Mac with no Xcode and no Python. Results depend on the macOS build (Apple updates the model with macOS), so every result carries it.

Here (any Mac with Xcode):

```sh
Scripts/make-bench-kit.sh          # → build/meboki-bench-kit.zip (runner signed ad hoc; MEBOKI_BENCH_IDENTITY=<identity> to sign with one)
```

On the macOS 26 Mac: unzip, then in Terminal

```sh
./run-apple.sh                     # no arguments: quality (US, UK), first token, default guardrails, 2 and 4 lanes, long-field page at 1/2/4
./run-gemma.sh [/Applications/Meboki.app]   # optional: the same cases through that app's llama-server with the downloaded Gemma 4 E2B/E4B
```

Both wrap the run in `caffeinate`, write into `results/` and zip it to `meboki-bench-results.zip`. If macOS blocks the runner after AirDrop or a download: `xattr -dr com.apple.quarantine .` in the kit folder. `run-gemma.sh` starts llama-server with the app's arguments (`-c 8192 -np 4 --kv-unified`) on a free port and stops it on exit.

Back here, one command scores everything:

```sh
python3 eval/bench_remote.py ~/Downloads/meboki-bench-results/results
```

A reply the model refused (guardrails), cut at the output cap, or failed on counts as the input unchanged, as in the app; the speed table lists the error names and counts.

## Before relying on a model file

Re-run `bench_ls.py` on the exact Hugging Face file the catalog points to. Quantizations from different publishers differ slightly.
