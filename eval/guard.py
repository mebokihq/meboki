import json, glob, sys, os, re, difflib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench import norm

def sim(a, b):
    return difflib.SequenceMatcher(None, a.lower(), b.lower()).ratio()

def style_only(a, b):
    k = lambda s: re.sub(r"[.!?]+$", "", s).lower().strip()
    return k(a) == k(b)

def guarded(inp, out):
    i, o = norm(inp), norm(out)
    if o == i: return i
    if sim(i, o) < 0.75: return i          # too different -> hallucination / translation / answer
    if style_only(i, o): return i          # only case / final punct -> ignore
    return o

if __name__ == "__main__":
    print(f"{'model':32s} {'prompt':8s} | err fixed | correct kept | casual kept | edge ok | dropped-true-fixes  (raw -> guarded)")
    for f in sorted(glob.glob((sys.argv[1] if len(sys.argv)>1 else "results")+"/*.json")):
        d = json.load(open(f)); rows = d["rows"]
        def score(kind, g):
            rs = [r for r in rows if r["kind"] == kind]
            ok = sum((norm(guarded(r["input"], r["output"])) if g else norm(r["output"])) in [norm(x) for x in r["refs"]] for r in rs)
            return ok, len(rs)
        lost = sum(1 for r in rows if r["kind"]=="err" and r["exact"] and norm(guarded(r["input"], r["output"])) not in [norm(x) for x in r["refs"]])
        s = lambda k: "%d->%d/%d" % (score(k,False)[0], score(k,True)[0], score(k,True)[1])
        print(f"{d['model']:32s} {d['prompt']:8s} | {s('err'):9s} | {s('ok'):12s} | {s('casual'):11s} | {s('edge'):7s} | {lost}   cold-load {d['warm_load_s']:.1f}s")
