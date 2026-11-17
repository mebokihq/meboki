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

## Before relying on a model file

Re-run `bench_ls.py` on the exact Hugging Face file the catalog points to. Quantizations from different publishers differ slightly.
