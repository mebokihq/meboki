import re, json, difflib
TOK = re.compile(r"[\w'’-]+|\s+|.", re.S)
def toks(s): return TOK.findall(s)
def hunks(a, b):
    """(aStart,aEnd,bStart,bEnd) over tokens, merged across a single whitespace token like Diff.edits."""
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    hs = [(i1, i2, j1, j2) for t, i1, i2, j1, j2 in sm.get_opcodes() if t != "equal"]
    out = []
    for h in hs:
        if out and h[0] == out[-1][1] + 1 and a[out[-1][1]].isspace():
            o = out[-1]; out[-1] = (o[0], h[1], o[2], h[3])
        else: out.append(h)
    return out
def feats(inp, outp):
    a, b = toks(inp), toks(outp)
    hs = hunks(a, b)
    words = lambda ts: [t for t in ts if re.match(r"[\w'’-]", t)]
    aw = len(words(a))
    chg_a = sum(len(words(a[h[0]:h[1]])) for h in hs)
    chg_b = sum(len(words(b[h[2]:h[3]])) for h in hs)
    big = max([max(len(words(a[h[0]:h[1]])), len(words(b[h[2]:h[3]]))) for h in hs] or [0])
    sim = difflib.SequenceMatcher(None, inp.lower(), outp.lower(), autojunk=False).ratio()
    # word-order moves: words present in both, but LCS shorter than multiset overlap
    wa, wb = [w.lower() for w in words(a)], [w.lower() for w in words(b)]
    lcs = sum(m.size for m in difflib.SequenceMatcher(None, wa, wb, autojunk=False).get_matching_blocks())
    from collections import Counter
    ov = sum((Counter(wa) & Counter(wb)).values())
    return dict(n=len(hs), words=aw, ratio=max(chg_a, chg_b) / max(aw, 1), big=big, sim=sim,
                moved=(ov - lcs) / max(aw, 1), density=len(hs) / max(aw, 1))
if __name__ == "__main__":
    import sys
    for r in json.load(open(sys.argv[1])):
        f = feats(r["input"], r["output"])
        print(f'{r["kind"][:3]} n={f["n"]:2d} w={f["words"]:2d} ratio={f["ratio"]:.2f} big={f["big"]:2d} sim={f["sim"]:.2f} mv={f["moved"]:.2f}')
        print("   IN :", r["input"]); print("   OUT:", r["output"])

def struct(inp, outp):
    """Hunk classes: 'word' = 1 word <-> 1 word (typo, inflection, case), 'punct' = no words either side,
    'multi' = everything else (inserted/deleted words, phrase replaced)."""
    a, b = toks(inp), toks(outp)
    isw = lambda t: bool(re.match(r"[\w'’-]", t))
    w = sum(1 for t in a if isw(t))
    ms, mw, kinds = 0, 0, []
    for (i1, i2, j1, j2) in hunks(a, b):
        na = sum(isw(t) for t in a[i1:i2]); nb = sum(isw(t) for t in b[j1:j2])
        if na == 0 and nb == 0: kinds.append("p")
        elif na == 1 and nb == 1: kinds.append("w")
        else: kinds.append("m"); ms += 1; mw += max(na, nb)
    return dict(w=w, kinds="".join(kinds), n=len(kinds), multi=ms, multiw=mw, mratio=mw / max(w, 1))
