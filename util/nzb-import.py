#!/usr/bin/env python3
"""Import zurg's NZB corpus into InfiniDysk through its SABnzbd-compatible API.

One-off migration helper for `docs/infinidysk-migration.md` (Phase 3). It reads
the NZBs and zurg's own metadata straight off the (read-only) zurg PVC, so
nothing is copied twice, and it only imports releases zurg had actually placed
in the library — each one into the SAB category that maps to its Plex tree, so
the *arr re-import can later scan one folder per app.

Release -> category comes from joining:
    nzbs/<name>.nzb  ->  data/<name>.zurgtorrent  (Hash)
                     ->  data/magic.json           (rows with that Hash)

zurg sanitises some characters when it writes the .zurgtorrent (backtick ->
nothing, apostrophe -> underscore), and a few NZBs carry suffixes, so the join
is exact first, then normalised (unambiguous matches only). Anything that does
not resolve to a placed release is skipped: this importer deliberately does not
import the ~1.7k "downloaded but never placed" releases (decision 2026-10-19).

Idempotent / resumable: names already present in queue or history are skipped,
so re-running after a pod restart continues where it stopped.

Env:
  INF_URL        http://infinidysk.media.svc.cluster.local:3000
  SAB_API_KEY    from infinidysk-secret (NZBDAV_CONFIG__API__KEY)
  NZB_DIR        /zurg/nzbs
  DATA_DIR       /zurg/data
  MAX_QUEUE      backpressure threshold (default 150)
  BATCH          pause between batches (default 50)
  DRY_RUN        1 = classify + report only, upload nothing
"""

import collections
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

API = os.environ.get("INF_URL", "http://infinidysk.media.svc.cluster.local:3000").rstrip("/")
KEY = os.environ["SAB_API_KEY"]
NZB_DIR = os.environ.get("NZB_DIR", "/zurg/nzbs")
DATA_DIR = os.environ.get("DATA_DIR", "/zurg/data")
MAX_QUEUE = int(os.environ.get("MAX_QUEUE", "150"))
BATCH = int(os.environ.get("BATCH", "50"))
DRY_RUN = os.environ.get("DRY_RUN") == "1"

TREES = {
    "plex_hd/shows": "sonarr",
    "plex_hd/movies": "radarr",
    "plex_4k/shows": "sonarr4k",
    "plex_4k/movies": "radarr4k",
    "other": "other",
}


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def tree_of(path):
    if not path:
        return None
    parts = path.split("/")
    if parts[0] in ("plex_hd", "plex_4k") and len(parts) > 1:
        return f"{parts[0]}/{parts[1]}"
    if parts[0] == "other":
        return "other"
    return None


def soft(name):
    for ch in ("'", "`", "\u2019", "\u00b4"):
        name = name.replace(ch, "_")
    return name


def hard(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


def build_categories():
    """release name -> SAB category, for placed releases only."""
    hash_trees = collections.defaultdict(set)
    with open(os.path.join(DATA_DIR, "magic.json")) as fh:
        for row in json.load(fh).get("rows", []):
            tree = tree_of(row.get("path"))
            if tree and row.get("hash"):
                hash_trees[row["hash"]].add(tree)

    exact, by_soft, by_hard = {}, collections.defaultdict(set), collections.defaultdict(set)
    for entry in os.listdir(DATA_DIR):
        if not entry.endswith(".zurgtorrent"):
            continue
        name = entry[: -len(".zurgtorrent")]
        try:
            with open(os.path.join(DATA_DIR, entry)) as fh:
                meta = json.load(fh)
        except (OSError, ValueError):
            continue
        cats = {TREES[t] for t in hash_trees.get(meta.get("Hash", ""), ()) if t in TREES}
        if len(cats) != 1:
            continue  # unplaced, tombstoned, or ambiguous: skipped on purpose
        cat = cats.pop()
        exact[name] = cat
        by_soft[soft(name)].add(cat)
        by_hard[hard(name)].add(cat)

    def lookup(name):
        if name in exact:
            return exact[name]
        for index, key in ((by_soft, soft(name)), (by_hard, hard(name))):
            hit = index.get(key)
            if hit and len(hit) == 1:
                return next(iter(hit))
        return None

    return lookup


def api(params, timeout=120):
    url = f"{API}/api?" + urllib.parse.urlencode({**params, "apikey": KEY, "output": "json"})
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.loads(resp.read().decode() or "{}")


def addfile(path, category):
    boundary = f"----infinidysk{uuid.uuid4().hex}"
    name = os.path.basename(path)
    with open(path, "rb") as fh:
        payload = fh.read()
    body = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="name"; filename="{name}"\r\n'
        f"Content-Type: application/x-nzb\r\n\r\n"
    ).encode() + payload + f"\r\n--{boundary}--\r\n".encode()
    url = (
        f"{API}/api?mode=addfile&cat={urllib.parse.quote(category)}"
        f"&apikey={KEY}&output=json"
    )
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.loads(resp.read().decode() or "{}")


def queue_depth():
    try:
        return int(api({"mode": "queue"}).get("queue", {}).get("noofslots", 0))
    except (urllib.error.URLError, ValueError) as exc:
        log(f"WARN queue poll failed: {exc}")
        return 0


def known_names():
    """Names already queued or in history, so a re-run resumes cleanly."""
    seen = set()
    for mode in ("queue", "history"):
        try:
            data = api({"mode": mode, "limit": "100000"})
        except (urllib.error.URLError, ValueError) as exc:
            log(f"WARN {mode} fetch failed: {exc}")
            continue
        for slot in data.get(mode, {}).get("slots", []):
            name = slot.get("filename") or slot.get("name") or ""
            seen.add(name[:-4] if name.endswith(".nzb") else name)
    return seen


def main():
    log(f"target {API} | nzbs {NZB_DIR} | meta {DATA_DIR} | dry_run={DRY_RUN}")
    lookup = build_categories()

    todo, skipped_meta, counts = [], 0, collections.Counter()
    for entry in sorted(os.listdir(NZB_DIR)):
        if not entry.endswith(".nzb"):
            continue
        name = entry[:-4]
        cat = lookup(name)
        if cat is None:
            skipped_meta += 1
            continue
        todo.append((name, cat))
        counts[cat] += 1

    log(f"placed releases to import: {len(todo)} {dict(counts)}")
    log(f"skipped (never placed in zurg's library): {skipped_meta}")
    if DRY_RUN:
        log("dry run: nothing uploaded")
        return 0

    done = known_names()
    log(f"already in queue/history: {len(done)}")
    todo = [(n, c) for n, c in todo if n not in done]
    log(f"remaining: {len(todo)}")

    added = failed = 0
    started = time.time()
    for index, (name, cat) in enumerate(todo, 1):
        path = os.path.join(NZB_DIR, f"{name}.nzb")
        try:
            resp = addfile(path, cat)
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            failed += 1
            log(f"FAIL {name}: {exc}")
            continue
        if not resp.get("status"):
            failed += 1
            log(f"REJECT {name}: {resp.get('error')}")
            continue
        added += 1
        if index % BATCH == 0:
            depth = 0
            while depth < MAX_QUEUE and index < len(todo):
                depth = queue_depth()
                if depth < MAX_QUEUE:
                    time.sleep(10)
                else:
                    break
            elapsed = time.time() - started
            rate = index / elapsed if elapsed else 0
            eta = (len(todo) - index) / rate / 3600 if rate else 0
            log(
                f"progress {index}/{len(todo)} added={added} failed={failed} "
                f"queue={depth} rate={rate:.2f}/s eta={eta:.1f}h"
            )

    log(f"done: added={added} failed={failed} in {(time.time()-started)/60:.1f} min")
    return 0


if __name__ == "__main__":
    sys.exit(main())
