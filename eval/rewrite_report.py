"""Rewrite detection (RewriteDetector): which model replies become one "Rewrite" fix, through the app's Core code.
usage: rewrite_report.py [-v]   (needs results_rewrite_e4b.json from rewrite_run.py and results_settings/)"""
import json, os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import dataset, rewrite_cases as rc
subprocess.run(["swift", "build", "-c", "debug", "--product", "meboki-eval-filter"], cwd=os.path.join(HERE, ".."), check=True, capture_output=True)
BIN = subprocess.run(["swift", "build", "--show-bin-path"], cwd=os.path.join(HERE, ".."), capture_output=True, text=True).stdout.strip() + "/meboki-eval-filter"
def run(rows):
    inp = "".join(json.dumps({"input": r["input"], "output": r["output"]}) + "\n" for r in rows)
    out = subprocess.run([BIN, "--rewrite"], input=inp, capture_output=True, text=True, check=True).stdout.splitlines()
    return [json.loads(l) for l in out]
rows = json.load(open(os.path.join(HERE, "results_rewrite_e4b.json")))
for r in json.load(open(os.path.join(HERE, "results_settings/gemma4-e4b-q4_0-text__fewshot.json")))["rows"]:
    if r["kind"] in ("err", "ok", "casual", "edge", "uk_err"): rows.append({"kind": "dataset-" + r["kind"], "input": r["input"], "output": r["output"]})
rows.append({"kind": "paragraph", "input": dataset.PARAGRAPH, "output": "Hi team, I wanted to give a quick update on the migration. We were able to move most of the services last week, but there is still a few issues with the payment service. The logs show timeouts when the database is under load. I think we should have tested this more carefully before. Let's discuss it on tomorrow's call, and please send me any information you have."})
res = run(rows)
tp = fp = fn = tn = 0; shown = []
for r, v in zip(rows, res):
    got = "rewrite" in v["fixes"]
    want = r["input"] in rc.EXPECT_REWRITE
    if got and want: tp += 1
    elif got: fp += 1; shown.append(("FALSE REWRITE", r, v))
    elif want: fn += 1; shown.append(("MISSED", r, v))
    else: tn += 1
    if got and "-v" in sys.argv: shown.append(("rewrite", r, v))
print(f"{len(rows)} replies: rewrite {tp + fp} (right {tp}, wrong {fp}), missed {fn}, separate fixes kept {tn}")
print("expected rewrites:", len(rc.EXPECT_REWRITE), "(one of them is rejected by the 0.75 similarity guard before any grouping)")
for tag, r, v in shown: print(f"\n{tag}: edits {v['edits']} -> {v['grouped']}\n  IN : {r['input']}\n  OUT: {r['output']}")

if "-t" in sys.argv:
    print("\nratio edits kind")
    for r, v in sorted(zip(rows, res), key=lambda z: -z[1].get("ratio", 0))[:24]:
        print(f"{v.get('ratio', 0):.2f} {v['edits']:2d} {r['kind'][:8]:8s} {'REWRITE' if r['input'] in rc.EXPECT_REWRITE else '       '} {r['input'][:80]}")
