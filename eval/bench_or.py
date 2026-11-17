"""Benchmark cloud models via OpenRouter with the same dataset + few-shot prompt.
usage: bench_or.py OUTDIR model [model ...]   (API key read from macOS Keychain, never printed)
"""
import json, sys, time, re, os, subprocess, urllib.request, urllib.error, threading
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench
from bench import PROMPTS

KEY = subprocess.run(["security", "find-generic-password", "-s", "OPENROUTER_API_KEY", "-w"],
                     capture_output=True, text=True).stdout.strip()
URL = "https://openrouter.ai/api/v1/chat/completions"
STATE = threading.local()
EXTRA = {"moonshotai/kimi-k2.5": {"provider": {"order": ["atlas-cloud", "siliconflow", "amazon-bedrock"], "allow_fallbacks": False}}}


def post(body):
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers={
        "Content-Type": "application/json", "Authorization": f"Bearer {KEY}", "X-Title": "gec-bench"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)


def call(model, prompt_key, text):
    user = f"<text>{text}</text>" if prompt_key == "fewshot" else text
    base = {"model": model, "temperature": 0, "max_tokens": 512, "usage": {"include": True},
            "messages": [{"role": "system", "content": PROMPTS[prompt_key]}, {"role": "user", "content": user}], **EXTRA.get(model, {})}
    variants = [{"reasoning": {"enabled": False}}, {"reasoning": {"effort": "minimal"}},
                {"reasoning": {"effort": "low"}}, {}]
    start = getattr(STATE, "variant", 0)
    last = None
    for vi in range(start, len(variants)):
        body = {**base, **variants[vi]}
        for attempt in range(3):
            t = time.time()
            try:
                d = post(body)
                wall = time.time() - t
                if "choices" not in d:
                    raise RuntimeError(json.dumps(d)[:300])
                STATE.variant = vi
                msg = d["choices"][0]["message"]
                raw = msg.get("content") or ""
                out = re.sub(r"<think>.*?</think>", "", raw, flags=re.S)
                u = d.get("usage", {})
                return out, {"wall": wall, "load": 0,
                             "prompt_tokens": u.get("prompt_tokens", 0), "prompt_s": 0,
                             "gen_tokens": u.get("completion_tokens", 0), "gen_s": max(wall, 1e-6),
                             "reasoning_tokens": (u.get("completion_tokens_details") or {}).get("reasoning_tokens", 0),
                             "cost": u.get("cost", 0) or 0, "provider": d.get("provider"),
                             "cached_tokens": (u.get("prompt_tokens_details") or {}).get("cached_tokens", 0) or 0,
                             "had_think": "<think>" in raw, "has_reasoning_field": bool(msg.get("reasoning")),
                             "variant": json.dumps(variants[vi])}
            except urllib.error.HTTPError as e:
                last = f"{e.code} {e.read()[:300]!r}"
                if e.code in (400, 404, 422):
                    break  # try next reasoning variant
                time.sleep(2 * (attempt + 1))
            except Exception as e:
                last = repr(e)
                time.sleep(2 * (attempt + 1))
    return f"<<ERROR {last}>>", {"wall": 0, "load": 0, "prompt_tokens": 0, "prompt_s": 0, "gen_tokens": 0,
                                  "gen_s": 1e-6, "reasoning_tokens": 0, "cost": 0, "provider": None, "variant": None}


def run_model(model, outdir):
    STATE.variant = 0
    bench.run(model, "fewshot", outdir)


if __name__ == "__main__":
    assert KEY.startswith("sk-or-"), "OpenRouter key not found in Keychain"
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    bench.call = call
    bench.ollama_ps = lambda m: "cloud"
    ths = [threading.Thread(target=run_model, args=(m, outdir)) for m in sys.argv[2:]]
    for t in ths: t.start()
    for t in ths: t.join()
