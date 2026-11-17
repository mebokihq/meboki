import json, glob, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench import norm
from guard import guarded

models = {m["id"]: m for m in json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "or_models.json")))["data"]}
d = sys.argv[1] if len(sys.argv) > 1 else "results_cloud"
rows_out = []
for f in sorted(glob.glob(os.path.join(d, "*.json"))):
    res = json.load(open(f)); rows = res["rows"]; mid = res["model"]
    pr = models[mid]["pricing"]; pin, pout = float(pr["prompt"]) * 1e6, float(pr["completion"]) * 1e6
    def sc(kind):
        rs = [r for r in rows if r["kind"] == kind]
        return sum(norm(guarded(r["input"], r["output"])) in [norm(x) for x in r["refs"]] for r in rs), len(rs)
    errs = sum(r["output"].startswith("<<ERROR") for r in rows)
    lat = sorted(r["wall"] for r in rows if r["wall"] > 0)
    cost = [r.get("cost", 0) for r in rows]
    tin = sum(r["prompt_tokens"] for r in rows) / len(rows); tout = sum(r["gen_tokens"] for r in rows) / len(rows)
    reas = sum(r.get("reasoning_tokens", 0) for r in rows) / len(rows)
    per_req = sum(cost) / len(rows)
    para = res["paragraph"]
    provs = sorted({r.get("provider") for r in rows if r.get("provider")})
    rows_out.append((mid, sc("err"), sc("ok"), sc("casual"), sc("edge"), lat[len(lat)//2], lat[int(len(lat)*.9)],
                     para["wall"], pin, pout, tin, tout, reas, per_req, para.get("cost", 0), errs, provs, para["output"]))

print(f"{'model':30s} err  ok  cas edge | p50   p90   para  | $in/M  $out/M | tok in/out/reas | $/sentence  $/para    $/1k checks | errors hosts")
for r in rows_out:
    (mid, e, o, c, g, p50, p90, pw, pin, pout, tin, tout, reas, per, pc, errs, provs, _) = r
    print(f"{mid:30s} {e[0]:2d}/{e[1]} {o[0]:2d}/{o[1]} {c[0]}/{c[1]} {g[0]}/{g[1]} | {p50:.2f}s {p90:.2f}s {pw:.2f}s | {pin:6.3f} {pout:6.3f} | {tin:4.0f}/{tout:3.0f}/{reas:3.0f} | "
          f"${per:.7f} ${pc:.7f} ${per*1000:.4f} | {errs} {','.join(provs)}")
print()
for r in rows_out:
    print(r[0], "PARA:", r[-1][:330].replace("\n", " "))
