"""Checks the code detector (Core `CodeDetector`): which fields the automatic check skips as code.

usage: code_report.py [-v]

No model involved. Every text goes through `CodeDetector.verdict` in the Swift tool
`meboki-eval-filter --code` (eval/filter), built here, so the numbers are the app's behavior.

Scored (precision first: a prose field taken for code silently loses its automatic check):
  prose     every benchmark input, the English language-gate texts, the repo's Markdown docs (and MEBOKI_PROSE_DIRS) as whole fields
            and per section with fenced code removed, the 300-fix benchmark page: none may count as code
  adversarial  eval/code_cases.json "prose" cases (chat, notes, legal text, poems, lists, tweets written to
            look like code): none may count as code
  code      the repo's own source (Swift, Python, shell, JSON, plist, HTML) as whole files: all must count
            as code
Reported only: eval/code_cases.json "code" cases, code snippets (every 20 lines of each source file; a slice from inside a docstring or a
comment block is prose, so 100% isn't expected) and doc sections that are mostly a fenced block.
"""
import glob, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import dataset as d
from language_report import bench_page_paragraphs

TOOL = os.path.join(ROOT, ".build", "debug", "meboki-eval-filter")
# The repo's Markdown docs, plus every .md file under the folders in MEBOKI_PROSE_DIRS (os.pathsep-separated),
# for scoring against a bigger prose set kept outside the repo.
DOCS = sorted({os.path.relpath(p, ROOT) for p in glob.glob(os.path.join(ROOT, "**", "*.md"), recursive=True)
               if os.sep + "." not in os.path.relpath(p, ROOT) and not os.path.relpath(p, ROOT).startswith(".")}
              | {os.path.abspath(p) for d in os.environ.get("MEBOKI_PROSE_DIRS", "").split(os.pathsep) if d
                 for p in glob.glob(os.path.join(d, "**", "*.md"), recursive=True)})
SOURCES = ["App/Sources/**/*.swift", "Packages/Core/**/*.swift", "eval/*.py", "eval/filter/*.swift",
           "Scripts/*.sh", "Package.swift", "eval/*.json", "App/Info.plist", "docs/bench/*.html"]
CHUNK = 20


def detect(texts):
    subprocess.run(["swift", "build", "--product", "meboki-eval-filter"], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL)
    lines = "\n".join(json.dumps({"text": t}, ensure_ascii=False) for t in texts) + "\n"
    p = subprocess.run([TOOL, "--code"], input=lines, capture_output=True, text=True, check=True)
    return [json.loads(l) for l in p.stdout.splitlines()]


def read(path):
    return open(os.path.join(ROOT, path), encoding="utf-8").read()


def doc_sections():
    """(prose sections with fenced code removed, sections that are mostly a fenced block)."""
    prose, mostly_code = [], []
    for name in DOCS:
        for sec in split_sections(read(name)):
            fences = "".join(re.findall(r"```.*?```", sec, flags=re.S))
            if len(fences) > len(sec) / 2:
                mostly_code.append((name, sec))
            stripped = re.sub(r"```.*?```", "", sec, flags=re.S)
            if stripped.strip():
                prose.append((name, stripped))
    return prose, mostly_code


def split_sections(text):
    """Splits at Markdown headings outside fenced blocks (a `# comment` in a bash block isn't a heading)."""
    out, cur, fenced = [], [], False
    for line in text.split("\n"):
        if line.startswith("```"):
            fenced = not fenced
        if not fenced and re.match(r"#{1,4} ", line) and cur:
            out.append("\n".join(cur))
            cur = []
        cur.append(line)
    out.append("\n".join(cur))
    return out


def sources():
    files = sorted({p for pat in SOURCES for p in glob.glob(os.path.join(ROOT, pat), recursive=True)})
    return [(os.path.relpath(p, ROOT), open(p, encoding="utf-8").read()) for p in files]


def chunks(text):
    lines = [l for l in text.split("\n") if l.strip()]
    return ["\n".join(lines[i:i + CHUNK]) for i in range(0, len(lines), CHUNK)]


def main():
    verbose = "-v" in sys.argv
    inputs = ([e[0] for e in d.ERR] + list(d.OK) + list(d.CASUAL) + [e[0] for e in d.EDGE] + [d.PARAGRAPH]
              + list(d.UK_OK) + [e[0] for e in d.UK_ERR] + list(d.CHAT) + [e[0] for e in d.CHAT_ERR]
              + [e[0] for e in d.LEVEL] + [e[0] for e in d.PROTECT] + list(d.LANG_ENGLISH))
    sections, mostly_code = doc_sections()
    prose = ([("benchmark", t) for t in inputs] + [(n, read(n)) for n in DOCS] + sections
             + [("bench page", "\n\n".join(bench_page_paragraphs()))])
    cases = json.load(open(os.path.join(HERE, "code_cases.json"), encoding="utf-8"))["cases"]
    prose += [("case " + c["name"], c["text"]) for c in cases if c["kind"] == "prose"]
    code_cases = [(c["name"], c["text"]) for c in cases if c["kind"] == "code"]
    files = sources()
    snippets = [(name, c) for name, text in files for c in chunks(text)]
    out = detect([t for _, t in prose] + [t for _, t in files] + [t for _, t in snippets]
                 + [t for _, t in mostly_code] + [t for _, t in code_cases])
    pr, fi = out[:len(prose)], out[len(prose):len(prose) + len(files)]
    sn = out[len(prose) + len(files):len(prose) + len(files) + len(snippets)]
    mc = out[len(prose) + len(files) + len(snippets):len(prose) + len(files) + len(snippets) + len(mostly_code)]
    cc = out[len(out) - len(code_cases):]

    failures = 0
    bad = [(n, t, v) for (n, t), v in zip(prose, pr) if v["code"]]
    chars = sum(len(t) for _, t in prose)
    print(f"prose     {len(prose) - len(bad)}/{len(prose)} kept as prose ({chars} chars)")
    for n, t, v in bad:
        print(f"  CODE?    {n}: {v['codeChars']}/{v['totalChars']} chars  {t.strip()[:70]!r}")
    failures += len(bad)
    if verbose:
        worst = sorted(((v["codeChars"] / max(1, v["totalChars"]), n, t) for (n, t), v in zip(prose, pr)
                        if v["codeChars"] >= 40), reverse=True)[:10]
        for share, n, t in worst:
            print(f"  share {share:.2f} {n}: {t.strip()[:70]!r}")

    missed = [(n, v) for (n, _), v in zip(files, fi) if not v["code"]]
    print(f"code      {len(files) - len(missed)}/{len(files)} source files taken for code")
    for n, v in missed:
        print(f"  PROSE?   {n}: {v['codeChars']}/{v['totalChars']} chars, {v['codeLines']}/{v['lines']} lines")
    failures += len(missed)

    hit = sum(1 for v in sn if v["code"])
    print(f"snippets  {hit}/{len(sn)} code ({100 * hit / max(1, len(sn)):.1f}%, not scored)")
    if verbose:
        for (n, t), v in zip(snippets, sn):
            if not v["code"]:
                print(f"  prose    {n}: {v['codeChars']}/{v['totalChars']}  {t.strip()[:70]!r}")
    print(f"cases     {sum(1 for v in cc if v['code'])}/{len(cc)} adversarial code cases taken for code (not scored)")
    if verbose:
        for (n, _), v in zip(code_cases, cc):
            if not v["code"]:
                print(f"  missed   {n}: {v['codeChars']}/{v['totalChars']} chars, strong {v['strongLines']}/{v['lines']}")
    print(f"fenced    {sum(1 for v in mc if v['code'])}/{len(mc)} doc sections that are mostly a code block "
          f"taken for code (not scored)")
    print("PASS" if failures == 0 else f"FAIL: {failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
