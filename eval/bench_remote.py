"""Scores a bench kit's results (meboki-eval-run JSON lines from another Mac) in one command.

usage: bench_remote.py RESULTS_DIR [OUTDIR]     (OUTDIR default: eval/results_apple)

RESULTS_DIR is the kit's `results/` folder (or the zip, unpacked). Every *.jsonl there is one runner run; its
meta line says the backend, label, prompt (us/uk), lanes and streaming. This script:
1. Turns each sequential, non-streamed run of the benchmark cases into the standard result JSON
   (`<label>__fewshot.json` / `<label>__fewshot-uk.json`, bench.py's format scored with bench.norm), so
   report.py, guard.py and settings_report.py read it unchanged. A refused, failed or cut-off reply counts as
   the input unchanged, as in the app (the sentence is left alone); `error` keeps the reason.
2. Prints the speed table: wall time per sentence p50/p90, paragraph, time to first token, cold vs warm first
   call, the cases at 1 / 2 / 4 lanes (and how many replies differ from 1 lane), the long-field page.
3. Runs report.py and guard.py on OUTDIR, and settings_report.py when both prompts are there.
"""
import glob
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench import norm
from export_cases import build_cases

SCORED = ("err", "ok", "casual", "edge")


def load(path):
    meta, rows, summary = None, [], None
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            o = json.loads(line)
            if o.get("type") == "meta":
                meta = o
            elif o.get("type") == "row":
                rows.append(o)
            elif o.get("type") == "summary":
                summary = o
    return meta, rows, summary


def label_of(meta):
    build = meta.get("machine", {}).get("build", "")
    return f"{meta['label']}-{build}" if build and build not in meta["label"] else meta["label"]


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * p))] if xs else float("nan")


def to_result(meta, rows):
    """bench.py's result JSON from runner rows (cases joined by id)."""
    by_id = {c["id"]: c for c in build_cases()}
    out_rows, para = [], None
    for r in rows:
        c = by_id.get(r["id"])
        if c is None or c["input"] != r["input"]:
            sys.exit(f"case {r['id']} doesn't match eval/dataset.py: re-export the kit's cases")
        rejected = r.get("rejected", False)
        output = r["input"] if rejected else r["output"].strip()
        timing = {"wall": r["wall"], "load": 0, "prompt_tokens": 0, "prompt_s": 0, "gen_tokens": 0, "gen_s": 0,
                  "truncated": r.get("truncated", False), "rejected": rejected,
                  **({"error": r["error"]} if "error" in r else {}), **({"ttft": r["ttft"]} if "ttft" in r else {})}
        if c["kind"] == "paragraph":
            para = {"output": output, **timing}
            continue
        o, nrefs = norm(output), [norm(x) for x in c["refs"]]
        out_rows.append({"kind": c["kind"], "label": c["label"], "input": c["input"], "output": output,
                         "refs": c["refs"], "exact": o in nrefs, "unchanged": o == norm(c["input"]),
                         **({"refs_by_level": c["refs_by_level"]} if "refs_by_level" in c else {}), **timing})
    prompt = "fewshot-uk" if meta["prompt"] == "uk" else "fewshot"
    built_in = meta["backend"].startswith("apple")
    return {"model": label_of(meta), "prompt": prompt, "backend": meta["backend"], "machine": meta.get("machine"),
            "warm_load_s": meta.get("cold_s", 0), "warm_s": meta.get("warm_s"),
            "ps": "built in (system process)" if built_in else "",
            "rows": out_rows, "paragraph": para or {"output": "", "wall": 0}}


def main():
    src = sys.argv[1]
    outdir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "results_apple")
    os.makedirs(outdir, exist_ok=True)
    runs = []
    for path in sorted(glob.glob(os.path.join(src, "**", "*.jsonl"), recursive=True)):
        meta, rows, summary = load(path)
        if meta is None:
            continue
        runs.append((path, meta, rows, summary))
    if not runs:
        sys.exit(f"no runner results (*.jsonl with a meta line) in {src}")

    machine = runs[0][1].get("machine", {})
    print(f"Mac: {machine.get('model')} · {machine.get('chip')} · {machine.get('ram_gb', 0):.0f} GB · "
          f"macOS {machine.get('macos')} ({machine.get('build')}) · Apple model: {machine.get('apple_model')}\n")

    seq = {}  # (label, prompt) -> rows of the sequential run
    for path, meta, rows, summary in runs:
        kinds = {r["kind"] for r in rows}
        if meta["lanes"] == 1 and not meta["stream"] and "page" not in kinds and "err" in kinds:
            res = to_result(meta, rows)
            fn = os.path.join(outdir, f"{res['model']}__{res['prompt']}.json")
            with open(fn, "w") as f:
                json.dump(res, f, ensure_ascii=False, indent=1)
            seq[(meta["label"], meta["prompt"])] = rows
            print(f"wrote {fn}")

    print("\nSpeed (seconds)")
    for path, meta, rows, summary in runs:
        name = f"{meta['label']} {meta['prompt']} lanes {meta['lanes']}{' stream' if meta['stream'] else ''}"
        kinds = {r["kind"] for r in rows}
        errors = {}
        for r in rows:
            if "error" in r:
                errors[r["error"]] = errors.get(r["error"], 0) + 1
        trunc = sum(1 for r in rows if r.get("truncated"))
        total = (summary or {}).get("total_wall", 0)
        line = f"  {name:34s} | {len(rows):3d} rows in {total:6.1f}"
        if "page" in kinds:
            line += f" | long-field page ({len(rows)} paragraphs)"
        else:
            walls = [r["wall"] for r in rows if r["kind"] in SCORED]
            line += f" | sentence p50 {pct(walls, .5):.2f} p90 {pct(walls, .9):.2f}"
            para = [r["wall"] for r in rows if r["kind"] == "paragraph"]
            if para:
                line += f" | paragraph {para[0]:.2f}"
            ttft = [r["ttft"] for r in rows if "ttft" in r and r["kind"] in SCORED]
            if ttft:
                line += f" | first token p50 {pct(ttft, .5):.2f} p90 {pct(ttft, .9):.2f}"
            base = seq.get((meta["label"], meta["prompt"]))
            if base is not None and (meta["lanes"] > 1 or meta["stream"]):
                b = {r["id"]: r["output"] for r in base}
                diff = sum(1 for r in rows if r["id"] in b and r["output"] != b[r["id"]])
                line += f" | {diff} replies differ from 1 lane"
        if "cold_s" in meta:
            line += f" | cold {meta['cold_s']:.2f} warm {meta['warm_s']:.2f}"
        if errors or trunc:
            line += " | " + ", ".join(f"{k} {v}" for k, v in sorted(errors.items())) + (f" truncated {trunc}" if trunc else "")
        print(line)

    print(flush=True)
    py = sys.executable
    subprocess.run([py, os.path.join(HERE, "report.py"), outdir])
    print(flush=True)
    subprocess.run([py, os.path.join(HERE, "guard.py"), outdir])
    if glob.glob(os.path.join(outdir, "*__fewshot-uk.json")):
        print(flush=True)
        subprocess.run([py, os.path.join(HERE, "settings_report.py"), outdir])


if __name__ == "__main__":
    main()
