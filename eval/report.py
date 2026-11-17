import json, glob, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench import norm, summarize

d = sys.argv[1]
show = sys.argv[2:]  # optional model substrings to dump mismatches
for f in sorted(glob.glob(os.path.join(d, "*.json"))):
    res = json.load(open(f))
    summarize(res)
    if any(s in f for s in show):
        for r in res["rows"]:
            if not r["exact"]:
                tag = "MISS" if r["unchanged"] and r["kind"] == "err" else ("FP" if r["kind"] != "err" else "DIFF")
                print(f"   {tag:4s} {r['kind']:6s} {r['input']!r}\n          -> {r['output']!r}")
        print("   PARA ->", res["paragraph"]["output"].replace("\n", " "))
        print("   ps:", res["ps"].strip())
