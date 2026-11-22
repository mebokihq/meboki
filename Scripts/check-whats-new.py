#!/usr/bin/env python3
"""Checks App/WhatsNew/whatsnew.json, the text of the What's new window shown after an update.

Usage:
  Scripts/check-whats-new.py                     the file's shape only (make-app.sh, every build)
  Scripts/check-whats-new.py <version>           also: the newest entry is <version> and differs from the last release
  Scripts/check-whats-new.py <version> --warn    the same, but problems with <version> only print a warning
  Scripts/check-whats-new.py <version> --html F  also write <version>'s entry as an HTML fragment (Sparkle's window)

The release check fails when:
  - the newest entry isn't <version> (nobody decided: write what changed, or add {"version", "date", "hidden": true}
    for a release that shows no window),
  - its text is the same as the entry before it (copied and not edited),
  - the file is the same as in the previous release tag (not touched since the last release).
Stdlib only.
"""
import html
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FOLDER = ROOT / "App" / "WhatsNew"
FILE = FOLDER / "whatsnew.json"
REL = FILE.relative_to(ROOT).as_posix()
KINDS = {"new", "improved", "fixed"}
KIND_LABEL = {"new": "New", "improved": "Improved", "fixed": "Fixed"}


def vparts(v):
    if not isinstance(v, str) or not re.fullmatch(r"\d+(\.\d+)*", v):
        return None
    return tuple(int(x) for x in v.split("."))


def vkey(v):
    p = vparts(v) or ()
    return p + (0,) * (4 - len(p))


def shape_errors(entries):
    errs = []
    if not isinstance(entries, list) or not entries:
        return ["the file must be a non-empty list of versions, newest first"]
    seen = set()
    for i, e in enumerate(entries):
        where = f"entry {i + 1}"
        if not isinstance(e, dict):
            errs.append(f"{where}: not an object")
            continue
        v = e.get("version")
        where = f"entry {v!r}"
        if vparts(v) is None:
            errs.append(f"{where}: version must look like 1.2.3")
        elif v in seen:
            errs.append(f"{where}: listed twice")
        seen.add(v)
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(e.get("date", ""))):
            errs.append(f"{where}: date must be yyyy-MM-dd")
        unknown = set(e) - {"version", "date", "highlights", "items", "hidden"}
        if unknown:
            errs.append(f"{where}: unknown keys {sorted(unknown)}")
        hs, items = e.get("highlights", []), e.get("items", [])
        if not isinstance(hs, list) or not isinstance(items, list):
            errs.append(f"{where}: highlights and items must be lists")
            continue
        if "hidden" in e and not isinstance(e["hidden"], bool):
            errs.append(f"{where}: hidden must be true or false")
        if not hs and not items and e.get("hidden") is not True:
            errs.append(f"{where}: has no highlights and no items (or set \"hidden\": true for no window)")
        for h in hs:
            if not isinstance(h, dict) or h.get("kind") not in KINDS:
                errs.append(f"{where}: highlight kind must be one of {sorted(KINDS)}")
                continue
            for k in ("title", "body"):
                if not str(h.get(k, "")).strip():
                    errs.append(f"{where}: highlight without {k}")
            if set(h) - {"kind", "symbol", "title", "body", "image"}:
                errs.append(f"{where}: highlight has unknown keys {sorted(set(h) - {'kind', 'symbol', 'title', 'body', 'image'})}")
            img = h.get("image")
            if img is not None:
                if ".." in str(img) or str(img).startswith("/"):
                    errs.append(f"{where}: image {img!r} must be a path inside App/WhatsNew")
                elif not (FOLDER / img).is_file():
                    errs.append(f"{where}: image {img!r} is missing (App/WhatsNew/{img})")
        for it in items:
            if not isinstance(it, dict) or it.get("kind") not in KINDS or not str(it.get("text", "")).strip():
                errs.append(f"{where}: every item needs a kind ({'/'.join(sorted(KINDS))}) and a text")
    good = [e.get("version") for e in entries if isinstance(e, dict) and vparts(e.get("version"))]
    if good != sorted(good, key=vkey, reverse=True):
        errs.append("versions must be listed newest first")
    return errs


def content(e):
    return json.dumps({"h": e.get("highlights", []), "i": e.get("items", [])}, sort_keys=True)


def last_tag():
    try:
        tags = subprocess.run(["git", "tag", "--list", "v*"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    except (OSError, subprocess.CalledProcessError):
        return None
    tags = [t for t in tags if vparts(t[1:])]
    return max(tags, key=lambda t: vkey(t[1:])) if tags else None


def file_at(tag):
    r = subprocess.run(["git", "show", f"{tag}:{REL}"], cwd=ROOT, capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def release_errors(entries, version):
    errs = []
    newest = entries[0]
    prev = entries[1] if len(entries) > 1 else None
    if newest.get("version") != version:
        since = f" since {newest.get('version')}" if vparts(newest.get("version")) else ""
        errs.append(f"{REL} has no entry for {version}: add one at the top with what changed{since}, "
                    f'or {{"version": "{version}", "date": "yyyy-MM-dd", "hidden": true}} for no window')
        return errs
    if newest.get("hidden") is True:
        pass  # a deliberate "no window for this release"
    elif prev is not None and content(newest) == content(prev):
        errs.append(f"the {version} entry has the same text as {prev.get('version')}: write what changed in {version}")
    tag = last_tag()
    if tag and tag != f"v{version}":
        old = file_at(tag)
        if old is not None and old == FILE.read_text(encoding="utf-8"):
            errs.append(f"{REL} hasn't changed since {tag}")
    return errs


def repeated_lines(entries):
    if len(entries) < 2 or entries[0].get("hidden") is True:
        return []
    def lines(e):
        return {h.get("title", "") for h in e.get("highlights", [])} | {i.get("text", "") for i in e.get("items", [])}
    return sorted(lines(entries[0]) & lines(entries[1]))


def html_notes(e):
    if e.get("hidden") is True:
        return f"<p>Meboki {html.escape(e['version'])}</p>\n"
    out = []
    for h in e.get("highlights", []):
        out.append(f"<h3>{html.escape(h['title'])}</h3><p>{html.escape(h['body'])}</p>")
    if e.get("items"):
        out.append("<ul>" + "".join(
            f"<li><b>{KIND_LABEL[i['kind']]}:</b> {html.escape(i['text'])}</li>" for i in e["items"]) + "</ul>")
    return "\n".join(out) + "\n"


def main(argv):
    args = argv[1:]
    warn = "--warn" in args
    html_out = None
    if "--html" in args:
        i = args.index("--html")
        html_out = args[i + 1] if i + 1 < len(args) else None
        if not html_out:
            print("--html needs a file name"); return 2
        del args[i:i + 2]
    args = [a for a in args if a != "--warn"]
    version = args[0] if args else None
    if version is not None and vparts(version) is None:
        print(f"usage: {argv[0]} [<version x.y.z> [--warn] [--html file]]"); return 2

    try:
        entries = json.loads(FILE.read_text(encoding="utf-8"))
    except FileNotFoundError:
        print(f"What's new: {REL} is missing"); return 1
    except json.JSONDecodeError as e:
        print(f"What's new: {REL} isn't valid JSON: {e}"); return 1
    errs = shape_errors(entries)
    if errs:
        print(f"What's new: {REL} has problems:")
        for e in errs: print(f"  - {e}")
        return 1
    if version is None:
        print(f"What's new: {REL} ok ({len(entries)} versions, newest {entries[0]['version']})")
        return 0

    errs = release_errors(entries, version)
    if errs:
        label = "warning" if warn else "error"
        print(f"What's new {label}:")
        for e in errs: print(f"  - {e}")
        if not warn:
            return 1
    else:
        for line in repeated_lines(entries):
            print(f"What's new warning: {line!r} is also in {entries[1]['version']}")
        if entries[0].get("hidden") is True:
            print(f"What's new: {version} ok (hidden: no window for this release)")
        else:
            print(f"What's new: {version} ok ({len(entries[0].get('highlights', []))} highlights, {len(entries[0].get('items', []))} items)")
        if html_out:
            Path(html_out).write_text(html_notes(entries[0]), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
