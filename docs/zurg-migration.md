# Migrating from AltMount to zurg

Working plan for replacing AltMount with zurg as the Usenet backend. End state:
zurg serves the whole library through `__magic__`, the \*arrs grab through zurg's
SABnzbd endpoint and organise inside `__magic__` (row writes, no bytes moved), Plex
and Jellyfin read only the `__magic__` tree, and AltMount + the symlink farm +
`altmount-sync-helper` are decommissioned.

Primary references (read these before executing):

- https://notes.debridmediamanager.com/migrate/ — shared migration page (trash guard,
  why `__magic__` replaces the symlink farm, what survives a re-add)
- https://notes.debridmediamanager.com/migrate/altmount/ — AltMount-specific page
- https://notes.debridmediamanager.com/guides/sonarr-radarr/ — SABnzbd endpoint +
  root-folder rules (**newer than the migrate pages; wins on conflicts**)
- https://notes.debridmediamanager.com/guides/magic/ — `__magic__` semantics
- https://notes.debridmediamanager.com/guides/plex/ — what zurg does to Plex settings

Nothing on this page is applied yet by writing it down; every phase lists its own
verification and rollback.

---

## Progress log

Legend: `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked.

| Phase | Status | Note |
| --- | --- | --- |
| 0 — reconcile the missing content | `[x]` | **dropped by decision (2026-10-01)** — the missing set will simply re-grab after Phase 3; worklist kept for reference only |
| 1 — Git: zurg sidecar on the four \*arrs | `[x]` | deployed & verified 2026-10-01 (PR #1329 / main `364cd58b`) |
| 2 — switch the download clients | `[x]` | deployed & verified 2026-10-01 (all four apps) |
| 3 — repoint \*arr root folders | `[x]` | bulk repoint done 2026-10-01; 0 files lost, old roots dropped |
| 4 — Plex cutover | `[ ]` | Jellyfin already done |
| 5 — teardown | `[ ]` | only after 1–2 quiet weeks |

### Log

- **2026-10-01** — **Feasibility verified** against the live cluster (main @
  `2452e306`). zurg healthy and serving (`magic` rows 5793, library 5491 releases,
  5 news accounts / 150 read conns), SABnzbd endpoint live with exactly the
  documented categories and `complete_dir`, tree counts match the table below,
  all four \*arrs still on the `AltMount (SABnzbd)` client with roots under
  `/aio/symlinks/...`, Jellyfin already zurg-only, Plex dual-pathed. Two doc
  drifts found: `plex_4k/movies` is now **426** old / **25** missing (table says
  425/24), and `sonarr4k` has **no** disabled `decypharr-*`/`nzbdav` clients.
- **2026-10-01** — worktree `zurg-migration` created off `main`; this plan doc was
  untracked in the main checkout and is committed here.
- **2026-10-01** — **Phase 1 done.** Added the writable `rclone-zurg` sidecar to
  `sonarr`, `radarr`, `sonarr4k`, `radarr4k` (mirrors the proven Plex sidecar,
  minus `--read-only`; `--vfs-cache-mode=full`, `--vfs-handle-caching=0`, pacer
  sleep disabled). FUSE / host-tmp / cache plumbing and the `/aio/remote/zurg`
  app mount added per app. The `rclone-altmount` sidecar and `/aio/symlinks`
  mount are deliberately **left in place** (removal is Phase 5), so rollback is
  simply reverting this commit. Validated with `flate test all -p
  ./kubernetes/flux/cluster` → 255 passed, 0 errors (only the 3 pre-existing
  offline warnings). **Deployed 2026-10-01 in PR #1329** (squash-merged as main
  `364cd58b`); Flux applied it unprompted and the rollout converged.
  **Verified live:** all four pods `3/3 Running` with `rclone-zurg` ready and 0
  restarts, and `/aio/remote/zurg/__magic__` lists `__all__ other plex_4k plex_hd`
  inside every \*arr pod — the Phase 1 acceptance criterion.
- **2026-10-01** — **Phase 0 started (classification only, no writes).** The
  missing set is **108** entries, not 91: `plex_hd/shows` 1, `plex_hd/movies` 64,
  `plex_4k/shows` 0, `plex_4k/movies` 25, `other` 18. All 108 were searched in
  zurg's library: **49 RECOVER** (title+year at the tree's resolution), **25
  WRONG-RES** (only the other resolution present), **30 GONE** (no match —
  including *all 18* `other` sports entries), **4 LOW-CONF**. Full per-entry table
  in [`zurg-migration-phase0-worklist.md`](./zurg-migration-phase0-worklist.md).
  Note for the next session: `zurg_library_search` `query` is a literal substring
  and misses dotted release names — use `regex`. Nothing placed yet, so the
  worklist is the resume point.
- **2026-10-01** — **Phase 0 dropped.** Decision: do not hand-place the missing
  entries. After Phase 3 repoints the roots, any series/movie whose content is
  absent shows as missing and the \*arrs re-grab it unattended; the 30 GONE
  entries are largely the 2026-09-30 cleanup's deliberate removals. The
  classification in
  [`zurg-migration-phase0-worklist.md`](./zurg-migration-phase0-worklist.md) is
  kept for reference only. Phase 0 therefore no longer gates Phase 3.
- **2026-10-01** — **Phase 2 done and verified.** Added a `zurg (Usenet)` SABnzbd
  client to every \*arr and disabled `AltMount (SABnzbd)`, all via the API
  (Sonarr/Radarr, port 80 for the Sonarrs and 7878 for the Radarrs; key from
  `zurg:/config/data/sabnzbd-apikey`). The client test passed in all four
  (zurg validates host, key, global config **and** category). One real grab per
  app then imported into `__magic__`, no bytes copied:

  | app | grabbed | landed at |
  | --- | --- | --- |
  | radarr | Hercules: Zero to Hero (1999) | `__magic__/plex_hd/movies/…` |
  | radarr4k | Django Unchained (2012) | `__magic__/plex_4k/movies/…` |
  | sonarr4k | Band of Brothers S01E01 | `__magic__/plex_4k/shows/…` |
  | sonarr | Last Week Tonight S13E24 | `__magic__/plex_hd/shows/…` |

  **Ordering correction (important):** the grab test in the Phase 2 text below
  cannot run while the \*arr root still points at `/aio/symlinks/...`. The import
  would be a cross-filesystem move (source on the zurg mount, destination on the
  symlinks PVC) and — with `copyUsingHardlinks=true` — falls back to a **full byte
  copy into a 10 GiB PVC**. The root must point into `__magic__` first, so each app's
  grab was preceded by the single-item root repoint from Phase 3. See the Phase 2
  execution notes added below.
- **2026-10-01** — **Phase 3 leading edge (5 items).** Repointed and re-matched
  without moving bytes: radarr movie `Hercules: Zero to Hero`, radarr4k movie
  `Django Unchained`, sonarr4k series `Band of Brothers`, sonarr series `Ted Lasso`
  (42 files re-matched, none lost) and `Last Week Tonight with John Oliver`. The bulk
  swap of the remaining ~1,100 items is still open.
- **2026-10-01** — **Phase 3 bulk repoint done.** Every item in all four \*arrs now
  references `/aio/remote/zurg/__magic__/...`, with **no file records lost** and no
  bytes moved (before → after file counts identical):

  | app | items | files before → after | new root |
  | --- | ---: | --- | --- |
  | sonarr | 104 series | 3455 → 3455 | `__magic__/plex_hd/shows` |
  | radarr | 508 movies | 499 → 499 | `__magic__/plex_hd/movies` |
  | sonarr4k | 88 series | 1368 → 1368 | `__magic__/plex_4k/shows` |
  | radarr4k | 471 movies | 424 → 424 | `__magic__/plex_4k/movies` |

  Done with a **bulk editor call per app** (`PUT /movie/editor` /
  `PUT /series/editor`, `moveFiles:false`), then `DELETE /rootfolder/<old-id>` to drop
  the `/aio/symlinks/...` roots. After that: **health is clear in all four apps**, every
  movie/episode file path reads `__magic__`, and the old symlink tree is unchanged
  (103 / 498 / 67 / 426 entries — nothing copied, nothing deleted). Phase 4 (Plex) is
  the remaining cutover; the \*arrs will now search for and re-grab genuinely missing
  content on their own schedule.

---

## State as of 2026-10-01 (verified against the cluster)

### Already done

- **zurg deployed and healthy** (`media/zurg`): 5 NNTP accounts (Eweka 50 + Frugal EU 75
  + Frugal US 25 primaries; Frugal bonus + Blocknews as `backup: true` fill),
  `magic.enabled: true`, `rclone_enabled: false` (consumers mount `/dav/` via their own
  rclone sidecars — zurg's built-in FUSE mount and its `union_writable` caveats are
  N/A here), `mount_path: /aio/remote/zurg`, hardened pod, 30Gi `/config` PVC, kopiur
  backups, Gatus + Authentik + `zurg.480p.com` routes.
- **Library populated and cleaned**: ~5,491 probed-clean releases after the 2026-09-30
  sweep (7,368 → removed broken/DMCA'd/unplayable; `__unplayable__` and
  `status_cannot_repair` at 0). Note this is **more releases than AltMount ever
  published** — AltMount silently refused some imports (size-biased segment check,
  see the migrate/altmount page), and zurg has them.
- **`__magic__` tree already organised** with \*arr naming (content already placed):

  | tree                | `__magic__` | symlink farm (old) | missing in zurg |
  |---------------------|------------:|-------------------:|----------------:|
  | `plex_hd/shows`     |         102 |                103 |               1 |
  | `plex_hd/movies`    |         434 |                498 |              64 |
  | `plex_4k/shows`     |          67 |                 67 |               0 |
  | `plex_4k/movies`    |         401 |                425 |              24 |
  | `other`             |          13 |                 31 |              18 |

- **SABnzbd endpoint live** (`sabnzbd.enabled: true`): verified
  `GET /api?mode=get_config` → `complete_dir: /aio/remote/zurg/__magic__/__all__`,
  categories `['*', 'other', 'radarr', 'radarr4k', 'sonarr', 'sonarr4k', 'nonplex']`.
  API key is generated, persists at `/config/data/sabnzbd-apikey` on the PVC (starts
  `9283e914`). The `zurg.480p.com` `/api` (Exact) + `/sabnzbd` route bypasses Authentik
  on purpose; in-cluster `http://zurg.media.svc.cluster.local:9999` works too.
- **Media-server push integration wired**: `plex_server_url` / `jellyfin_server_url`
  point at the in-cluster Services, tokens in Infisical, targeted scans fire on
  `__magic__` placements/renames/repairs (grouped per section by prefix-matching
  `mount_path`). `plex_settings_policy: guard` keeps `autoEmptyTrash=0` — **verified
  `value="0"` on the Plex server** — plus the FSEvent guards.
- **Jellyfin: cut over.** All 5 libraries point at `/aio/remote/zurg/__magic__/...`
  only; its altmount sidecar is commented out in the helmrelease (parked, reversible).
- **Plex: dual-pathed, so duplicates are expected right now.** Every section carries
  BOTH the old symlink location and the new zurg location (Movies
  `/aio/symlinks/plex_hd/movies` + `/aio/remote/zurg/__magic__/plex_hd/movies`, same
  pattern for Movies 4K, Shows, Shows 4K, Other). The magic guide is explicit that a
  library scanning two views of the same content finds everything twice — this is the
  transitional state Phase 4 resolves. Plex pod has both rclone sidecars (altmount +
  zurg, zurg is `--read-only`). Old locations not yet removed; trash not yet emptied.
- **`zurg-debug`** exists as the canonical writable consumer sidecar (flag set: no
  `--links`, `--vfs-handle-caching=0`, `RCLONE_CONFIG_ZURG_PACER_MIN_SLEEP: "0"`).

### Still on AltMount (the remaining work)

- **All four \*arrs import into the symlink farm and grab from AltMount:**
  - sonarr → root `/aio/symlinks/plex_hd/shows`, download client `AltMount (SABnzbd)`
    at `altmount.media.svc.cluster.local:8080` (enabled)
  - radarr → root `/aio/symlinks/plex_hd/movies`, same client (enabled)
  - sonarr4k → root `/aio/symlinks/plex_4k/shows`, same client (enabled)
  - radarr4k → root `/aio/symlinks/plex_4k/movies`, same client (enabled)
  - No remote path mappings anywhere (both sides share paths — same model works for
    zurg because `mount_path` matches what consumers mount, so still none needed).
  - The \*arr pods have **no zurg sidecar yet** — they only mount altmount
    (`/aio/remote/altmount`, with `--links`) and the `symlinks` PVC (`/aio/symlinks`).
    Old flow: \*arr "imports" by moving rclone-surfaced symlinks from
    `/aio/remote/altmount/complete/<cat>/<release>/` into the root folder; targets
    point back into the altmount mount.
  - Disabled download clients (`decypharr-*`, `nzbdav`) still configured in sonarr /
    radarr / radarr4k — dead config, ignore or delete.
- **`other` pipeline**: `altmount-sync-helper` copies `/aio/symlinks/complete/other` →
  `/aio/symlinks/other` (non-\*arr content: F1, TT). Dies with AltMount; replacement is
  manual `__magic__` placement or grabs via the `other`/`nonplex` zurg categories.
- **`symlinks` PVC** (CephFS, kopiur-backed) is still the live library for Plex and the
  \*arrs. Also mounted by `media-debug`, and by the disabled `decypharr`/`nzbdav`
  stacks.
- **AltMount itself** still runs (single copy of the original NZBs as `.nzbz` in its
  config PVC — that store is the rollback until the very end).

### zurg behaviour to know before executing (from the guides)

- **Move inside `__magic__` = row write; move out of it = hard 403.** Root folders
  must be inside `__magic__` (ours are) and must sit **beside** `__all__`, never at or
  above it (both \*arrs health-check that). `__magic__/__all__` itself is computed —
  nothing can be written into it; it is only the folder clients import *from*.
- **The SABnzbd endpoint now pre-checks articles** (the caveat on the migrate/altmount
  page — "does not yet check whether a post's articles are still on the news server" —
  is **outdated**; the sonarr-radarr guide supersedes it): before a job reports
  Completed, zurg STATs the first article of each content file. A release with gone
  articles reports **Failed**, which the \*arrs blocklist and re-grab unattended. A
  check that cannot *complete* (account down/throttled) keeps the job Queued and only
  fails it after 30 attempts spanning ≥3h; a release that leaves the library fails its
  job after 15 min. Remaining gap: the check samples the **first** article per file,
  so mid-file damage still only fails on read — the 2026-09-30 probe sweep makes that
  rare here.
- **One zurg queue, filtered by category and nothing else.** Two clients sharing a
  category see each other's jobs. Our four apps get four distinct categories
  (`sonarr`/`sonarr4k`/`radarr`/`radarr4k`) — never reuse one.
- **No progress bars**: a job is Queued or Completed, nothing between. A job sitting
  Queued right after the release appears is normal for a poll or two (zurg is settling
  exact file sizes — importing early is what causes "File move incomplete" errors).
  >60 simultaneously-ready jobs drain through history sixty at a time; expected.
- **\*arr deletes are tombstones, not destruction** (`magic.allow_delete: false`
  here): quality upgrades and post-import job-folder cleanup just hide the entry; the
  release stays in `__all__`. Tombstones are undoable on the `/magic/` dashboard.
  Re-grabbing a release an earlier import already emptied reports Failed → the client
  blocklists and picks another. Correct.
- **The `data/local` gauge on `/magic/` is the copy-detector.** A correct import is a
  rename (row write) and the number does not move; a rising sidecars/`data/local`
  number means a client is copying bytes instead of moving. Watch it during Phases
  2–3.
- **Never rename a file in `nzbs/`** — the release's identity derives from that
  filename; renaming orphans the release and every placement made from it. State lives
  in `nzbs/*.nzb`, `data/magic.json` (placements + tombstones), `data/sabnzbd-jobs.json`
  — all on the kopiur-backed `/config` PVC.
- **Sample clips / `only_show_the_biggest_file`**: that knob only applies to
  `directories:` filter views, which we deliberately do not use — and inside
  `__magic__` there is no directory config at all. What saves us is the real-tree
  shape of `__magic__/__all__`: samples/extras stay in their `Sample/`/`Extras`
  subfolder, and the \*arr import scan skips files under extras-type subfolders. A
  sample only reaches Plex if one is manually placed top-level in a scanned tree.
- **RAR releases come back under the poster's name, one directory deeper** than
  AltMount had them (AltMount renamed the payload to the folder name). Strictly better
  for \*arr parsing; only matters for Phase 0 hand-placements.
- **Plex settings**: `guard` (our policy) writes `autoEmptyTrash=0`,
  `FSEventLibrary{Updates,PartialScan}Enabled=0`, keeps the DB backup task on.
  zurg's own trash sweep (`plex_trash_sweep_every_mins`, 60 min default) needs
  `plex_database_path` — impossible cross-pod, so it stands down and **Plex trash
  accumulates until emptied by hand**; `docs/plex-trash-sweep.md` is the
  designed-but-unimplemented fix. `enforce` would additionally kill the
  whole-file-decode Butler tasks (deep analysis, ad markers, VAD) — the lever if
  nightly maintenance ever pulls serious Usenet bytes.

---

## Phase 0 — reconcile the missing content (do first, no config changes)

**Status: list generated and classified 2026-10-01; placements not started.** See
[`zurg-migration-phase0-worklist.md`](./zurg-migration-phase0-worklist.md) for the
per-entry verdicts and candidate releases.

**108** old-tree entries have no counterpart in the `__magic__` trees (1 HD show,
64 HD movies, 25 4K movies, 18 other — full lists regenerable with the diff one-liner
at the bottom). Classification against zurg's library: 49 RECOVER, 25 WRONG-RES, 30
GONE, 4 LOW-CONF. For each missing name, in this order:

1. **Find the release in zurg** — MCP `zurg_release_search` or look under
   `__magic__/__all__`. If present: place it with a magic move
   (`mv .../__magic__/__all__/<release> .../__magic__/<tree>/<Name>` — a whole release
   folder moves as a single row; no bytes). Match the existing \*arr naming scheme of
   the target tree (`Name (Year) {tmdb-…}` etc.).
2. **If absent** it was likely removed in the 2026-09-30 cleanup (broken/DMCA'd).
   Don't restore those blindly — either accept the loss or let the \*arr re-grab after
   Phase 3 (they show as missing once root folders move; that's the natural queue).
3. The `other` gap is mostly recent F1/TT grabs — decide per item; the sync-helper
   keeps covering new grabs until it's retired.
4. Expect the reverse too: zurg-only releases (the ones AltMount refused) have no old
   counterpart. They stay harmless in `__all__` unless placed.

Also verify one sample stream per tree from both Plex and Jellyfin before touching
anything (playback through `/dav/` + rclone full-cache is the whole point).

## Phase 1 — Git: give the \*arrs a zurg sidecar

One PR. For each of `sonarr`, `radarr`, `sonarr4k`, `radarr4k`:

- Add an `rclone-zurg` container copied from `media/zurg-debug` (same flags),
  **writable** (no `--read-only` — the \*arrs MOVE inside `__magic__` and PUT
  posters/`.nfo` sidecars; Plex/Jellyfin stay read-only), mounting
  `zurg:/` at `/aio/remote/zurg` via `hostPath: /tmp/rclone-<app>-zurg` with
  Bidirectional/HostToContainer propagation, same `fuse`/`rclone-cache-zurg`/
  `host-tmp` plumbing as the jellyfin/plex blocks.
- Keep the altmount sidecar and `/aio/symlinks` mount for now (removal is Phase 5).
- Probe target: `test -e /host-mount/rclone-<app>-zurg/version.txt`.
- The sonarr-radarr guide's "bind the parent with rslave" warning targets zurg's
  built-in FUSE mount — N/A here: each sidecar owns its mount lifecycle
  (`umount -l` + fresh mount on sidecar start, probes catch staleness).

After reconcile: `ls /aio/remote/zurg/__magic__` inside each \*arr pod must show
`__all__ other plex_4k plex_hd`.

## Phase 2 — switch the download clients (one app at a time)

In each \*arr (Settings → Download Clients), add a **new** SABnzbd client rather than
editing in place, so rollback is "re-enable AltMount, disable zurg":

- Name `zurg (Usenet)`, Host `zurg.media.svc.cluster.local`, Port `9999`, no SSL,
  API key from `kubectl exec -n media deploy/zurg -- cat /config/data/sabnzbd-apikey`,
  Category `sonarr` / `radarr` / `sonarr4k` / `radarr4k` (all already in zurg's list —
  a category zurg doesn't know fails the test with "Category … does not exist"; the
  existing AltMount client has no category and zurg's `*` wildcard would catch it,
  but explicit is better and keeps the four queues separated), Remove Completed/Failed
  on.
- **Test → Save → disable the AltMount client** (don't delete it yet).
- Then one real grab per app: pick a single episode/movie, confirm
  grab → Queued → (article check) → Completed → import-by-rename lands in the right
  `__magic__` tree, and zurg pushes the Plex/Jellyfin scan. History shows **Grabbed**
  then **Movie/Series Imported** seconds apart with nothing downloaded. Watch the
  `/magic/` dashboard: placements +1, and `data/local` must NOT grow.

### Phase 2 execution notes (measured 2026-10-01)

- **Do the single-item root repoint before the grab.** With the root still on
  `/aio/symlinks/...` the import is a cross-device move and `copyUsingHardlinks=true`
  makes it copy — a full Usenet read into a 10 GiB PVC. Repoint first (Phase 3 step),
  then grab; the import then stays inside the zurg mount and is a row write.
- **API shape used.** The `Sabnzbd`/`SabnzbdSettings` schema comes from
  `GET /api/v3/downloadclient/schema`; POST it back with `host`,
  `port`=9999, `useSsl`=false, `apiKey`=zurg's key, `tvCategory`/`movieCategory`
  filled (Sonarr/Radarr use different field names) and the priorities left at
  their `-100` default. `POST …/downloadclient/test` first (200 = all four checks),
  then `POST …/downloadclient`, then `PUT …/downloadclient/<id>` with
  `enable:false` on the AltMount client.
- **Root-folder repoint is an *editor* call, not a per-item PUT.**
  `PUT /api/v3/movie/{id}` silently ignores a changed `rootFolderPath` (returns 202,
  no change). Use `PUT /api/v3/movie/editor` with
  `{"movieIds":[…],"rootFolderPath":…,"moveFiles":false}` — likewise
  `PUT /api/v3/series/editor` with `seriesIds`. Add the `__magic__` path as a root
  folder (`POST /api/v3/rootfolder`) first; it reports a virtual ~1 PiB free space,
  which is the zurg mount answering rather than a real disk.
- **Fail-closed works.** Rotted releases are reported by zurg with a reason
  (`4 of its files report damage … likely aged off the spool`, `no usable PAR2
  index`, `N article(s) missing`), the job goes Failed, and the \*arr records
  `downloadFailed` and blocklists — then re-grabs another release unattended. Seen
  live on 2021-era `Ted Lasso` S02: the release, and then a season pack, both failed
  on damaged articles and Sonarr moved on; a fresh 2026 episode of
  `Last Week Tonight` imported in ~40 s.
- **Root repoint keeps files.** Repointing `Ted Lasso` (42 files) moved its root to
  `__magic__` and re-matched all 42 — no loss, no copy. (Terminology: there are no
  symlinks in `__magic__`; the files are real virtual files served by zurg, and a
  rescan simply re-matches them to the \*arr's records.)

## Phase 3 — repoint \*arr root folders (no file moves!)

**Status: done 2026-10-01 for all four \*arrs** (see the progress log). The bulk
repoint used one editor call per app and dropped the old roots; 0 files lost, health
clear, old symlink tree untouched. Note the ordering constraint recorded under Phase 2:
the grab test needs the root already in `__magic__`, so a single item was repointed
before Phase 2's grabs. API shapes that work: `PUT /api/v3/movie/editor` and
`PUT /api/v3/series/editor` with `{"movieIds"|"seriesIds":[…],"rootFolderPath":…,
"moveFiles":false}` (a per-item `PUT /movie/{id}` ignores the change), then
`DELETE /api/v3/rootfolder/<id>` for the old root — which removes the entry only.

Terminology: there are no symlinks in `__magic__`. The files are real virtual files
served by zurg; a rescan **re-matches** them to the \*arr's records and rewrites the
stored paths — that is the whole operation, and it moves no bytes.

The DMM-documented sequence is: add `__magic__` roots → Library Import adopts what's
there → remove old root without deleting. Ours differs deliberately: the `__magic__`
tree is **already organised with final \*arr names** and every series/movie is already
tracked against the old paths, so adoption has nothing to do (Library Import only
picks up untracked folders). The equivalent for tracked items is a path swap:

1. Add `/aio/remote/zurg/__magic__/plex_hd/shows` (+ `movies`, `plex_4k/...`) as
   **new root folders** in Settings → Media Management. Verification in the dialog
   itself: browsing shows `__all__` + siblings, **Free Space** reads a (virtual,
   petabyte-scale) number rather than 0/error, **Unmapped Folders** counts what's
   already there.
2. Move each series/movie onto the new root **without moving files** — per-item editor
   or API (`PUT /api/v3/{series|movie}/{id}` with the new `rootFolderPath`, no move).
   The migrate page's "never change a root folder to point into `__magic__`" warning is
   about answering **Yes** to the move prompt: a move whose destination leaves the
   source filesystem is a copy, and a copy downloads the whole library through Usenet.
   (Inside `__magic__` zurg would refuse the move with a 403; the old symlink tree is
   outside `__magic__`, so the old→new direction is the dangerous one.)
3. Do **one series first**: swap path → Rescan → confirm episode files re-match (names
   already match the \*arr scheme, so parsing should just work) and the file paths in
   the UI read `/aio/remote/zurg/__magic__/...`. Watch `/magic/`'s `data/local` gauge
   throughout — growth means something is copying.
4. Then the rest, per app. Afterwards remove the old `/aio/symlinks/...` root folder
   **without deleting files**, and confirm health checks go green.

Fallback shortcut if the UI/API route proves painful at ~1,100 items: prefix-rewrite
the paths in the Postgres tables (`/aio/symlinks` → `/aio/remote/zurg/__magic__`)
while the app is stopped. Unsupported surgery; snapshot/backup first; only if needed.

## Phase 4 — finish the Plex cutover (Jellyfin is done)

Per section (Movies, Movies 4K, Shows, Shows 4K, Other):

1. While dual-pathed, confirm the new-location items matched to the same
   `plex://` GUIDs as the old ones — spot-check watch states/resume offsets on a
   handful. Watch state re-attaches via GUID; a **mismatch loses it**, so catch
   mismatches here, not after trash day. Expect Recently Added to flood — `added_at`
   does not survive, by design.
2. Remove the **old** `/aio/symlinks/...` location from the section, scan.
   Old items go to trash (re-verify `autoEmptyTrash=0` on the day — it is the one
   guard that makes this reversible).
3. **Leave the trash alone until everything streams.** Emptying it is the only
   irreversible step: collections, playlists, ratings and chosen artwork die with the
   old items. Spot-check a representative sample first (an HD movie, a 4K movie, a
   show, an `other` item; direct play + a transcode). Remember zurg's own sweep can't
   run cross-pod (`plex_database_path`), so trash otherwise accumulates until the
   `docs/plex-trash-sweep.md` sidecar exists — empty by hand, deliberately.
4. While in there: confirm "Generate video preview thumbnails" stays off for these
   libraries (a thumbnail pass on a streaming mount is a full file read).
5. Then remove Plex's `rclone-altmount` sidecar + `/aio/symlinks` mount in Git.

Jellyfin: nothing to do except playback spot-checks (already zurg-only).

## Phase 5 — teardown (only after 1–2 quiet weeks)

In roughly this order, separate commits:

1. `media/altmount-sync-helper` — delete the app (its `other` pipeline is replaced by
   zurg categories + `__magic__` placement).
2. \*arr helmreleases — drop the `rclone-altmount` sidecar, the `symlinks` PVC mount,
   and the leftover `fuse`/`rclone-cache-altmount`/`altmount` persistence; delete the
   disabled `AltMount (SABnzbd)` (and dead `decypharr-*`/`nzbdav`) download clients
   in-app.
3. `media/plex` — altmount sidecar + symlinks mount (if not done in Phase 4).
4. `media/media-debug` — drop its altmount/symlinks mounts (keep or fold into
   `zurg-debug`).
5. `media/altmount` — scale to 0 first, stream-test for a few days, then remove the
   app (helmrelease, routes incl. `httproute-webdav`/`httproute-sabnzbd`,
   SecurityPolicy + its blueprint entries in
   `authentik/app/blueprints/forward-auth.yaml`, DNSEndpoint, Gatus endpoint, ks wiring
   in `media/kustomization.yaml`). **Keep the altmount config PVC** — it holds the only
   other copy of the NZBs (`.nzbz` store). Delete it (and its kopiur SnapshotPolicy)
   only when "we can never go back" is genuinely true. If a full NZB export is wanted
   first, the recovery script is on the DMM AltMount page (`.nzbz` → `.nzb` via
   `strings` on the `.meta` files, or the JWT-authed `export-nzb` API).
6. `media/symlinks` — the app is already an empty kustomization that only exists to
   back the PVC into kopiur; once nothing mounts it, remove the app and finally the
   PVC itself (snapshot remains in the kopia repo regardless).
7. Update `AGENTS.md` (zurg notes stay, altmount-era findings get pruned) and close
   the `feat/zurg` evaluation: zurg becomes the permanent backend, not an experiment.

### Explicitly not doing

- **No symlink farm for zurg** — `__magic__` replaces it; a farm over `__all__` dangles
  on every rename/`{shorthash}` suffix, placements don't.
- **No `directories:` filter views** — a second address for the same releases; a media
  server scanning both finds everything twice (this is also why the current
  dual-pathed Plex state shows duplicates).
- **No `.strm`** — every read would still proxy through zurg; only trades away the VFS
  cache.
- **Watchlist/Seerr acquisition stays off** — the \*arrs own grabs.
- **No Plex trash automation yet** — zurg's built-in sweep needs `plex_database_path`
  (same-host only). See `docs/plex-trash-sweep.md`.

## Rollback

- Phases 0–3: everything is additive or UI-level. Rollback = re-enable the AltMount
  download client; symlink farm untouched until Phase 5. \*arr deletes on the zurg
  side are tombstones, undoable on `/magic/`.
- Phase 4: rollback = re-add the old section location (items return from trash if not
  emptied) + uncomment the jellyfin/plex altmount blocks.
- Phase 5: the point of no return is deleting the altmount config PVC. Until then a
  full revert is re-deploying altmount + re-enabling clients; the symlinks still point
  into the altmount mount.

## Appendix — regeneration one-liners

```sh
# tree diff (old symlink farm vs __magic__)
kubectl exec -n media deploy/media-debug -c app -- sh -c \
  'for p in plex_hd/shows plex_hd/movies plex_4k/shows plex_4k/movies other; do echo "## $p"; ls "/aio/symlinks/$p"; done' > /tmp/old.txt
kubectl exec -n media deploy/zurg-debug -c rclone-zurg -- sh -c \
  'for p in plex_hd/shows plex_hd/movies plex_4k/shows plex_4k/movies other; do echo "## $p"; ls "/host-mount/rclone-zurg-debug/__magic__/$p"; done' > /tmp/new.txt
# then diff per ## section

# zurg SABnzbd API key
kubectl exec -n media deploy/zurg -- cat /config/data/sabnzbd-apikey

# Plex trash guard (must print value="0")
PLEX_TOKEN=$(kubectl exec -n media deploy/zurg -- sh -c 'grep plex_token: /config/config.yml' | awk '{print $2}' | tr -d '"')
kubectl exec -n media deploy/plex -c app -- sh -c \
  "curl -s 'http://127.0.0.1:32400/:/prefs?X-Plex-Token=$PLEX_TOKEN'" | tr '>' '\n' | grep autoEmptyTrash
```
