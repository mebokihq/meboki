"""Scores the Settings › Writing options (stage 9) on recorded model replies, using the app's own Core code.

usage: settings_report.py RESULTS_DIR [model-substring ...]

Needs bench_ls.py runs with both prompts in RESULTS_DIR (`<label>__fewshot.json` for US, `<label>__fewshot-uk.json`
for UK). Each reply goes through `ProofreadEngine.process` (judge → diff → edit filters) in the Swift tool
`meboki-eval-filter` (eval/filter), built here with `swift build`, so the numbers are the app's behavior.

Rows:
  baseline   US prompt, PostFilter only (no edit filters): must equal guard.py's guarded scores
  default    US, Full, protect on, casual off (what a non-chat app gets out of the box)
  UK         UK prompt (+ the same filters)
  casual     US, casual on (chat apps, or an app set to Casual)
  grammar / spelling   check levels
"""
import json, glob, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from bench import norm, PROMPTS

TOOL = os.path.join(ROOT, ".build", "debug", "meboki-eval-filter")

CONFIGS = [
    # name, prompt file suffix, options
    ("baseline", "fewshot", dict(variant="US", level="full", casual=False, protect=False, unfiltered=True)),
    ("default", "fewshot", dict(variant="US", level="full", casual=False, protect=True)),
    ("UK", "fewshot-uk", dict(variant="UK", level="full", casual=False, protect=True)),
    ("casual", "fewshot", dict(variant="US", level="full", casual=True, protect=True)),
    ("UK+casual", "fewshot-uk", dict(variant="UK", level="full", casual=True, protect=True)),
    ("grammar", "fewshot", dict(variant="US", level="grammar", casual=False, protect=True)),
    ("spelling", "fewshot", dict(variant="US", level="spelling", casual=False, protect=True)),
    ("no-protect", "fewshot", dict(variant="US", level="full", casual=False, protect=False)),
]
KINDS = [("err", 45), ("ok", 22), ("casual", 6), ("edge", 7), ("uk_ok", 8), ("uk_err", 6), ("chat", 8),
         ("chat_err", 6), ("level", 7), ("protect", 7)]


def build_tool():
    subprocess.run(["swift", "build", "--product", "meboki-eval-filter"], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL)
    prompts = json.loads(subprocess.run([TOOL, "--print-prompts"], capture_output=True, text=True, check=True).stdout)
    if prompts["US"] != PROMPTS["fewshot"] or prompts["UK"] != PROMPTS["fewshot-uk"]:
        sys.exit("bench.py prompts differ from Prompt.swift: fix one of them before trusting any number")


def run_tool(items):
    """items: list of (input, output, opts) → list of final texts."""
    lines = []
    for inp, out, o in items:
        if o.get("unfiltered"):
            o = dict(o, protect=False)
        lines.append(json.dumps({"input": inp, "output": out, "variant": o["variant"], "level": o["level"],
                                 "casual": o["casual"], "protect": o["protect"], "unfiltered": o.get("unfiltered", False)},
                                ensure_ascii=False))
    p = subprocess.run([TOOL], input="\n".join(lines) + "\n", capture_output=True, text=True, check=True)
    return [json.loads(l)["final"] for l in p.stdout.splitlines()]


def main():
    d = sys.argv[1]
    show = sys.argv[2:]
    build_tool()
    labels = sorted({os.path.basename(f).split("__")[0] for f in glob.glob(os.path.join(d, "*__fewshot-uk.json"))})
    header = f"{'model':24s} {'config':10s} | " + " | ".join(f"{k:>8s}" for k, _ in KINDS)
    print(header)
    for label in labels:
        files = {p: json.load(open(os.path.join(d, f"{label}__{p}.json"))) for p in ("fewshot", "fewshot-uk")}
        for name, prompt, opts in CONFIGS:
            rows = files[prompt]["rows"]
            finals = run_tool([(r["input"], r["output"], opts) for r in rows])
            cells, misses = [], []
            for kind, total in KINDS:
                rs = [(r, f) for r, f in zip(rows, finals) if r["kind"] == kind]
                ok = 0
                for r, f in rs:
                    refs = r.get("refs_by_level", {}).get(opts["level"], r["refs"])
                    hit = norm(f) in [norm(x) for x in refs]
                    ok += hit
                    if not hit:
                        misses.append((kind, r["input"], f))
                cells.append(f"{ok:>3d}/{len(rs):<4d}" if rs else f"{'-':>8s}")
            print(f"{label:24s} {name:10s} | " + " | ".join(cells))
            if any(s in label for s in show):
                for kind, inp, f in misses:
                    print(f"      {kind:8s} {inp!r}\n               -> {f!r}")


if __name__ == "__main__":
    main()
