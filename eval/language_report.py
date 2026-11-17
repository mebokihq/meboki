"""Checks the language gate (Core `LanguageGate`): which sentences a check leaves out as not English.

usage: language_report.py [-v]

No model involved. Every text goes through `LanguageGate.foreignRanges` in the Swift tool
`meboki-eval-filter --language` (eval/filter), built here, so the numbers are the app's behavior.

Scored:
  english    every input of the benchmark (all sets but EDGE "russian") and LANG_ENGLISH: nothing may be left out
             (a miss here silently loses real fixes)
  docs       the repo's own English prose (README, plus MEBOKI_PROSE_DIRS docs: jargon, names, links, tables) and
             the 300-fix long-field page (docs/bench): nothing may be left out
  foreign    LANG_FOREIGN paragraphs and EDGE "russian": every sentence left out
  mixed      LANG_MIXED: exactly the foreign sentences left out
Reported only: LANG_SHORT (too short to judge, still sent).
"""
import glob, html, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import dataset as d

TOOL = os.path.join(ROOT, ".build", "debug", "meboki-eval-filter")
BENCH_PAGE = os.path.join(ROOT, "docs", "bench", "long-field-300-fixes.html")
# README.md, plus every .md file under the folders in MEBOKI_PROSE_DIRS (os.pathsep-separated): more English
# prose kept outside the repo.
DOCS = ["README.md"] + sorted(os.path.abspath(p) for d in os.environ.get("MEBOKI_PROSE_DIRS", "").split(os.pathsep) if d
                              for p in glob.glob(os.path.join(d, "**", "*.md"), recursive=True))


def gate(texts):
    subprocess.run(["swift", "build", "--product", "meboki-eval-filter"], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL)
    lines = "\n".join(json.dumps({"text": t}, ensure_ascii=False) for t in texts) + "\n"
    p = subprocess.run([TOOL, "--language"], input=lines, capture_output=True, text=True, check=True)
    return [json.loads(l)["foreign"] for l in p.stdout.splitlines()]


def bench_page_paragraphs():
    src = open(BENCH_PAGE, encoding="utf-8").read()
    body = re.sub(r"<script.*?</script>|<style.*?</style>|<head.*?</head>", "", src, flags=re.S)
    body = re.sub(r"</?(?:p|li|ul|ol|div|br)\b[^>]*>", "\n", body)  # blocks → lines; inline tags just go
    text = html.unescape(re.sub(r"<[^>]+>", "", body))
    return [p.strip() for p in text.split("\n") if len(p.strip()) > 2]


def doc_paragraphs():
    """Prose lines of the repo's Markdown docs, with fenced code dropped and table cells as separate lines."""
    out = []
    for name in DOCS:
        text = open(os.path.join(ROOT, name), encoding="utf-8").read()
        text = re.sub(r"```.*?```", "", text, flags=re.S)
        for line in text.split("\n"):
            for cell in line.split("|"):
                cell = re.sub(r"^\s*(?:#+|[-*>]|\d+\.)\s*", "", cell).strip()
                if len(cell) > 2 and not set(cell) <= set("-: "):
                    out.append(cell)
    return out


def main():
    verbose = "-v" in sys.argv
    english = ([e[0] for e in d.ERR] + list(d.OK) + list(d.CASUAL) + [e[0] for e in d.EDGE if e[2] != "russian"]
               + [d.PARAGRAPH] + list(d.UK_OK) + [e[0] for e in d.UK_ERR] + list(d.CHAT) + [e[0] for e in d.CHAT_ERR]
               + [e[0] for e in d.LEVEL] + [e[0] for e in d.PROTECT] + list(d.LANG_ENGLISH))
    page = doc_paragraphs() + bench_page_paragraphs()
    foreign = [t for t, _ in d.LANG_FOREIGN] + [e[0] for e in d.EDGE if e[2] == "russian"]
    mixed = [t for t, _ in d.LANG_MIXED]
    short = list(d.LANG_SHORT)
    out = gate(english + page + foreign + mixed + short)
    i = 0

    def take(n):
        nonlocal i
        part = out[i:i + n]
        i += n
        return part

    failures = 0
    eng, pg, fo, mx, sh = take(len(english)), take(len(page)), take(len(foreign)), take(len(mixed)), take(len(short))

    bad = [(t, f) for t, f in zip(english, eng) if f]
    print(f"english   {len(english) - len(bad)}/{len(english)} fully kept")
    for t, f in bad:
        print(f"  LEFT OUT {f!r}  in  {t[:80]!r}")
    failures += len(bad)

    bad_pg = [(t, f) for t, f in zip(page, pg) if f]
    chars = sum(len(t) for t in page)
    print(f"docs      {len(page) - len(bad_pg)}/{len(page)} paragraphs fully kept ({chars} chars)")
    for t, f in bad_pg:
        print(f"  LEFT OUT {f!r}  in  {t[:80]!r}")
    failures += len(bad_pg)

    def sentences_of(t):
        return [s for s in re.split(r"(?<=[.!?。])\s*", t) if s.strip()]

    missed = 0
    for t, f in zip(foreign, fo):
        left = "".join(f).replace(" ", "")
        whole = t.replace(" ", "")
        if left != whole:
            missed += 1
            print(f"  SENT     {t[:80]!r}  (left out: {f!r})")
    print(f"foreign   {len(foreign) - missed}/{len(foreign)} fully left out")
    failures += missed

    wrong = 0
    for (t, want), f in zip(d.LANG_MIXED, mx):
        if f != want:
            wrong += 1
            print(f"  MIXED    {t[:60]!r}: left out {f!r}, want {want!r}")
    print(f"mixed     {len(mx) - wrong}/{len(mx)} exact")
    failures += wrong

    print(f"short     {sum(1 for f in sh if f)}/{len(sh)} left out (not scored; too short to judge is expected)")
    if verbose:
        for t, f in zip(short, sh):
            print(f"  {'left out' if f else 'sent    '} {t!r}")
    print("PASS" if failures == 0 else f"FAIL: {failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
