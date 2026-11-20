"""Exports the benchmark cases for meboki-eval-run (eval/runner), which runs on a Mac without Python.

usage: export_cases.py OUTDIR
writes OUTDIR/cases.jsonl  every bench.py case (80 + the 42 settings cases) and the 5-sentence paragraph
       OUTDIR/page.jsonl   the paragraphs of docs/bench/long-field-300-fixes.html (long-field timing)

One JSON object per line: {"id", "kind", "input", "label", "refs"[, "refs_by_level"]}. The ids are stable, so
bench_remote.py joins the runner's rows back to the dataset by id. Same order and kinds as bench.run.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from dataset import ERR, OK, CASUAL, EDGE, PARAGRAPH, UK_OK, UK_ERR, CHAT, CHAT_ERR, LEVEL, PROTECT


def build_cases():
    """bench.run's case list (settings sets included), with ids."""
    cases = [("err", i, refs, None) for i, refs in ERR] + \
            [("ok", t, [t], None) for t in OK] + \
            [("casual", t, [t], None) for t in CASUAL] + \
            [("edge", i, refs, lab) for i, refs, lab in EDGE] + \
            [("uk_ok", t, [t], None) for t in UK_OK] + \
            [("uk_err", i, refs, None) for i, refs in UK_ERR] + \
            [("chat", t, [t], None) for t in CHAT] + \
            [("chat_err", i, refs, None) for i, refs in CHAT_ERR] + \
            [("level", i, refs, None) for i, refs in LEVEL] + \
            [("protect", i, refs, None) for i, refs in PROTECT]
    out, counts = [], {}
    for kind, inp, refs, lab in cases:
        counts[kind] = counts.get(kind, 0) + 1
        row = {"id": f"{kind}-{counts[kind]:03d}", "kind": kind, "input": inp, "label": lab}
        if isinstance(refs, dict):
            row["refs_by_level"] = refs
            row["refs"] = refs["full"]
        else:
            row["refs"] = refs
        out.append(row)
    out.append({"id": "paragraph", "kind": "paragraph", "input": PARAGRAPH, "label": None, "refs": []})
    return out


def page_cases():
    import bench_parallel
    return [{"id": f"page-{i + 1:03d}", "kind": "page", "input": p, "label": None, "refs": []}
            for i, p in enumerate(bench_parallel.page_paragraphs())]


def write(path, rows):
    with open(path, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"{path}: {len(rows)} cases")


if __name__ == "__main__":
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    write(os.path.join(outdir, "cases.jsonl"), build_cases())
    write(os.path.join(outdir, "page.jsonl"), page_cases())
