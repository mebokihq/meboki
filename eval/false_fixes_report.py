"""Replays the false-fix regression file through the app's Core code (part of the eval gate).

usage: false_fixes_report.py [-v] [FILE]   (default: false_fixes.jsonl next to this script)

Each line of the file is one wrong suggestion seen once (a user report or a found pattern) with the model reply
that caused it and the text the check must produce instead. `meboki-eval-filter --false-fixes` runs it through
`CheckPipeline` with that reply in place of the model, so the cache, the post-filters and the settings are the
app's. A case with "steps" runs several checks in order on one pipeline (typing, cache reuse).

Adding a case: one JSON line, either {"id", "source", "input", "output", "expected", "options"?} or
{"id", "source", "note", "steps": [{"text", "replies": {sent text: reply}, "expected", "typing"?, "cursor"?,
"notSent"?: [substrings that must never reach the model]}]}.
"expected" is the whole text after the kept fixes. Options: variant US|UK, level full|grammar|spelling, casual,
protect (default true). Exit status 1 when any case fails.
"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOOL = os.path.join(ROOT, ".build", "debug", "meboki-eval-filter")


def main():
    args = [a for a in sys.argv[1:] if a != "-v"]
    verbose = "-v" in sys.argv[1:]
    path = args[0] if args else os.path.join(HERE, "false_fixes.jsonl")
    subprocess.run(["swift", "build", "--product", "meboki-eval-filter"], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL)
    with open(path, encoding="utf-8") as f:
        lines = [l for l in f if l.strip()]
    p = subprocess.run([TOOL, "--false-fixes"], input="".join(lines), capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"meboki-eval-filter failed:\n{p.stderr}")
    results = [json.loads(l) for l in p.stdout.splitlines() if l.strip()]
    failed = [r for r in results if not r["ok"]]
    for r in results:
        if r["ok"] and not verbose:
            continue
        print(f"{'ok  ' if r['ok'] else 'FAIL'} {r['id']} step {r['step']}")
        if not r["ok"] or verbose:
            print(f"  expected: {r['expected']}\n  got:      {r['got']}\n  sent:     {r['sent']}")
            if r.get("leaked"):
                print(f"  leaked to the model: {r['leaked']}")
    cases = len({r["id"] for r in results})
    print(f"{cases} cases, {len(results)} checks: {len(results) - len(failed)} ok, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
