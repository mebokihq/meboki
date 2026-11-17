"""Benchmark text-only GGUF via bundled llama-server (OpenAI-compatible API), same dataset/prompts as bench.py.
usage: bench_ls.py OUTDIR LABEL GGUF_PATH [prompt,prompt]
"""
import json, sys, time, re, os, subprocess, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench
from bench import PROMPTS, summarize

LS = os.environ.get("LLAMA_SERVER", "/Applications/Ollama.app/Contents/Resources/llama-server")
PORT = 18080
URL = f"http://127.0.0.1:{PORT}/v1/chat/completions"


def call(model, prompt_key, text):
    user = f"<text>{text}</text>" if prompt_key in bench.WRAPPED else text
    body = {
        "messages": [{"role": "system", "content": PROMPTS[prompt_key]}, {"role": "user", "content": user}],
        "temperature": 0, "max_tokens": 256, "seed": 1,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    t = time.time()
    with urllib.request.urlopen(req, timeout=300) as r:
        d = json.load(r)
    wall = time.time() - t
    out = d["choices"][0]["message"]["content"] or ""
    out = re.sub(r"<think>.*?</think>", "", out, flags=re.S)
    tm = d.get("timings", {})
    return out, {"wall": wall, "load": 0, "prompt_tokens": tm.get("prompt_n", 0), "prompt_s": tm.get("prompt_ms", 0) / 1e3,
                 "gen_tokens": tm.get("predicted_n", 0), "gen_s": tm.get("predicted_ms", 0) / 1e3}


def rss_of(pid):
    r = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return int(r or 0) / 1024 / 1024


if __name__ == "__main__":
    outdir, label, gguf = sys.argv[1], sys.argv[2], sys.argv[3]
    prompts = (sys.argv[4] if len(sys.argv) > 4 else "fewshot").split(",")
    os.makedirs(outdir, exist_ok=True)
    t0 = time.time()
    p = subprocess.Popen([LS, "--model", gguf, "--port", str(PORT), "--host", "127.0.0.1", "-c", "2048", "-np", "1",
                          "--jinja", "--no-webui", "-ngl", "999"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(240):
            try:
                if b"ok" in urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=2).read():
                    break
            except Exception:
                pass
            time.sleep(0.5)
        load_s = time.time() - t0
        bench.call = call
        peak = [0.0]
        bench.ollama_ps = lambda m: (peak.__setitem__(0, max(peak[0], rss_of(p.pid))), f"RSS {rss_of(p.pid):.2f} GB")[1]
        for pk in prompts:
            bench.run(label, pk, outdir)
            print(f"   server start+load {load_s:.1f}s, peak RSS {peak[0]:.2f} GB", flush=True)
    finally:
        p.terminate(); p.wait()
