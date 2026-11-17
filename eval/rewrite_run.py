"""Record the shipped model's replies for rewrite_cases (llama-server already running). usage: rewrite_run.py URL OUT.json"""
import json, sys, os, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench, rewrite_cases as rc
url, out = sys.argv[1], sys.argv[2]
rows = []
for kind, items in (("local", rc.LOCAL), ("awkward", rc.AWKWARD)):
    for t in items:
        body = {"messages": [{"role": "system", "content": bench.PROMPTS["fewshot"]},
                             {"role": "user", "content": f"<text>{t}</text>"}],
                "temperature": 0, "max_tokens": 512, "seed": 1, "chat_template_kwargs": {"enable_thinking": False}}
        req = urllib.request.Request(url + "/v1/chat/completions", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
        d = json.load(urllib.request.urlopen(req, timeout=300))
        rows.append({"kind": kind, "input": t, "output": d["choices"][0]["message"]["content"] or ""})
json.dump(rows, open(out, "w"), indent=1, ensure_ascii=False)
print(len(rows))
