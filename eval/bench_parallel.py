"""Parallel requests to llama-server (Optimization A3): do several requests at once give the same replies, and
how much faster is a long field?

usage: bench_parallel.py OUTDIR LABEL GGUF_PATH NP [prompt,prompt]

Starts the bundled llama-server the way the app would with NP slots (`-c 8192 -np NP --kv-unified`), then:
1. Runs every benchmark case (bench.py's list, same JSON as bench_ls.py) with NP requests in flight, so
   guard.py / settings_report.py score it like any run, and lists replies that differ from the matching
   sequential run in OUTDIR (label without the `-npN` suffix) if there is one.
2. Sends the paragraphs of docs/bench/long-field-300-fixes.html (154 requests) one at a time and NP at a
   time, with the app's max_tokens (characters + 64), and prints wall times.
"""
import concurrent.futures as cf
import html
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench
import bench_ls
from bench import PROMPTS

LS = os.environ.get("LLAMA_SERVER", os.path.join(HERE, "..", "Vendor", "bin", "llama-server"))
PORT = 18081
bench_ls.URL = f"http://127.0.0.1:{PORT}/v1/chat/completions"


def page_paragraphs():
    page = open(os.path.join(HERE, "..", "docs", "bench", "long-field-300-fixes.html"), encoding="utf-8").read()
    body = page.split('contenteditable="true">', 1)[1].split("</div>", 1)[0]
    paras = [html.unescape(re.sub(r"<[^>]+>", "", p)).strip() for p in re.split(r"</p>|</li>", body)]
    return [p for p in paras if re.search(r"[A-Za-z]", p)]


def app_call(text):
    """The app's request (LLMClient.correct): fewshot prompt, max_tokens = UTF-16 length + 64."""
    body = {
        "messages": [{"role": "system", "content": PROMPTS["fewshot"]}, {"role": "user", "content": f"<text>{text}</text>"}],
        "temperature": 0, "seed": 1, "max_tokens": len(text.encode("utf-16-le")) // 2 + 64,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    req = urllib.request.Request(bench_ls.URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.load(r)["choices"][0]["message"]["content"]


def timed(texts, workers):
    t = time.time()
    with cf.ThreadPoolExecutor(workers) as ex:
        outs = list(ex.map(app_call, texts))
    return time.time() - t, outs


def run_cases(label, prompt_key, outdir, workers):
    # Dry pass: collect the inputs bench.run sends, in order.
    inputs = []
    real_call, real_dump, real_sum = bench.call, json.dump, bench.summarize
    bench.call = lambda m, pk, text: (inputs.append(text), ("", {"wall": 0, "load": 0}))[1]
    json.dump = lambda *a, **k: None
    bench.summarize = lambda res: None
    try:
        bench.run(label, prompt_key, outdir)
    finally:
        json.dump, bench.summarize = real_dump, real_sum
    # All of them, `workers` at a time; then bench.run again, answered from the results.
    with cf.ThreadPoolExecutor(workers) as ex:
        futures = {t: ex.submit(bench_ls.call, label, prompt_key, t) for t in dict.fromkeys(inputs)}
        answers = {t: f.result() for t, f in futures.items()}
    bench.call = lambda m, pk, text: answers[text]
    try:
        bench.run(label, prompt_key, outdir)
    finally:
        bench.call = real_call


def compare(outdir, label, prompt_key):
    base = re.sub(r"-np\d+$", "", label)
    fa = os.path.join(outdir, f"{base}__{prompt_key}.json")
    fb = os.path.join(outdir, f"{label}__{prompt_key}.json")
    if base == label or not os.path.exists(fa):
        print(f"   (no sequential run {fa} to compare with)")
        return
    a, b = json.load(open(fa)), json.load(open(fb))
    diff = [(x["input"], x["output"], y["output"]) for x, y in zip(a["rows"], b["rows"]) if x["output"] != y["output"]]
    if a["paragraph"]["output"] != b["paragraph"]["output"]:
        diff.append(("PARAGRAPH", a["paragraph"]["output"], b["paragraph"]["output"]))
    print(f"   {prompt_key}: {len(diff)} of {len(a['rows']) + 1} replies differ from {base}")
    for inp, x, y in diff:
        print(f"     {inp[:70]!r}\n       seq: {x[:90]!r}\n       par: {y[:90]!r}")


if __name__ == "__main__":
    outdir, label, gguf, np_ = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
    prompts = (sys.argv[5] if len(sys.argv) > 5 else "fewshot").split(",")
    os.makedirs(outdir, exist_ok=True)
    bench.ollama_ps = lambda m: ""
    # BENCH_KVU=0: separate KV per slot (BENCH_CTX total context, split across the slots) instead of one shared pool.
    kvu = os.environ.get("BENCH_KVU", "1") == "1"
    args = [LS, "--model", gguf, "--port", str(PORT), "--host", "127.0.0.1", "-c", os.environ.get("BENCH_CTX", "8192"),
            "-np", str(np_), "--jinja", "--no-webui", "-ngl", "999"] + (["--kv-unified"] if np_ > 1 and kvu else [])
    p = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(240):
            try:
                if b"ok" in urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=2).read():
                    break
            except Exception:
                pass
            time.sleep(0.5)
        app_call("This is a test.")
        paras = page_paragraphs()
        for w in sorted({1, np_}):
            dt, _ = timed(paras, w)
            print(f"long-field page: {len(paras)} requests, {w} at a time: {dt:.1f} s "
                  f"(server -np {np_}), RSS {bench_ls.rss_of(p.pid):.2f} GB", flush=True)
        for pk in prompts:
            run_cases(label, pk, outdir, np_)
            compare(outdir, label, pk)
    finally:
        p.terminate()
        p.wait()
