# BookOrbit feature rollout — setup checklist

Living list of every BookOrbit capability worth turning on in this cluster, and the order to do it
in. Instance: `bookorbit.brauni.dev`, image `ghcr.io/bookorbit/bookorbit` (v3.9.0), libraries
`Brauni` (1) and `Zeli` (2). Last updated 2026-11-19.

## Ground rules

- **Git does not own this config.** BookOrbit keeps its settings in its own Postgres database
  (`app_settings` + per-user tables), so nearly everything below is a UI/API action, not a manifest.
  Git still owns: env/secrets in the ExternalSecret, the Cilium policy, the route/Gatus/Homepage
  annotations, the CNPG database and the kopiur claim. Anything needing a _new_ credential goes to
  Infisical as `/bookorbit/<NAME>` and then into `kubernetes/apps/media/bookorbit/app/externalsecret.yaml`.
- **Automation auth** is an API key (`bok_…`), stored at `/bookorbit/API_KEY`. Session tokens can't be
  minted from `JWT_SECRET` (they need a live `auth_sessions` row). Interactive-only routes (password
  resets, session management, API-key CRUD) are refused to API keys by design.
- **Two users**: `brauni` (superuser, sees both libraries), `zeli` (viewer on `Zeli` only).
  `allow_registration=false` — new accounts are admin-created with a 15-minute reset link.
- Every phase should leave the instance usable; nothing here is all-or-nothing.

## State legend

`live` already working · `partial` half-wired · `todo` not started · `blocked` needs a decision

## Inventory

### Reading & library

| Feature                                 | What it gives us                                | Needs                                      | State         |
| --------------------------------------- | ----------------------------------------------- | ------------------------------------------ | ------------- |
| Library + scanner                       | 165 books across 2 libraries, `book_per_folder` | —                                          | live          |
| Watch folders / auto-scan cron          | New files imported without clicking Scan        | RBD fs events are reliable → `watch: true` | todo          |
| Reader (ebook/PDF/comics/DjVu)          | In-browser reading with progress sync           | —                                          | live          |
| Annotations, bookmarks, notebooks       | Highlights + notes per book                     | —                                          | live (unused) |
| Collections / Smart Scopes              | Saved filters and curated shelves               | Define a few                               | todo          |
| Series / authors / narrators / taxonomy | Browsable entity pages                          | Fed by metadata                            | partial       |
| Chapter editor / chapter health         | Fix broken chapter maps for audiobooks          | Audiobooks present                         | todo          |
| Statistics, year review, achievements   | Reading stats per user                          | —                                          | live (unused) |

### Acquisition & delivery

| Feature                                  | What it gives us                                                                                                       | Needs                                                    | State                                   |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- | --------------------------------------- |
| Library Dock                             | Review-then-file inbox, per-library docks                                                                              | Dock settings + auto-file policy                         | partial (watcher runs, no dock enabled) |
| Browser/device uploads                   | Drag-and-drop into dock or straight into a library                                                                     | —                                                        | live                                    |
| **Search & download (built-in sources)** | Internet Archive, Project Gutenberg, LibriVox, Libgen, Anna's, MAM plugins; HTTP-direct, **no download client needed** | Enable sources in Settings → Requests                    | todo                                    |
| **Search & download (Prowlarr/torznab)** | Reuse existing Prowlarr indexers                                                                                       | Prowlarr torznab endpoint + API key                      | todo                                    |
| Download clients                         | qBittorrent / transmission / deluge / rTorrent / SABnzbd / NZBGet / TorBox                                             | External client + **shared filesystem path** (see below) | blocked                                 |
| **Book requests**                        | Users request titles → auto-approve → grab → land in dock                                                              | Indexers + (optionally) a client + destination mapping   | todo                                    |
| Watch downloads / reconciliation         | Detect completed grabs outside the request flow                                                                        | Client configured                                        | todo                                    |
| Migration importer                       | Import from Grimmory/Audiobookshelf/CWA                                                                                | Only if we re-migrate                                    | todo (unlikely)                         |

### Integrations & devices

| Feature                       | What it gives us                                  | Needs                                                  | State           |
| ----------------------------- | ------------------------------------------------- | ------------------------------------------------------ | --------------- |
| **Hardcover**                 | Two-way read-status/progress/rating sync          | Per-user Hardcover API token + Settings → Hardcover    | todo            |
| Kobo sync                     | Native Kobo store-style sync                      | `kobo_sync` perm (granted to zeli), user shelf mapping | todo            |
| KOReader sync                 | Progress sync for KOReader                        | `koreader_sync` perm + client plugin                   | todo            |
| OPDS                          | Catalog for any OPDS reader                       | `opds_access` perm, enabled by default                 | live            |
| Send to e-reader (delivery)   | Email a book to a device address                  | **SMTP** (not configured)                              | blocked on SMTP |
| Email / notifications         | Password resets, request notifications            | SMTP (`/bookorbit/SMTP_*`?)                            | blocked         |
| Authentik SSO (OIDC)          | Single sign-on, no second password                | Authentik blueprint + `/bookorbit/OIDC_CLIENT_SECRET`  | todo            |
| Readwise / StoryGraph sync    | Export highlights / read status to those services | Per-user tokens                                        | todo            |
| Mobile app / App Attest / PWA | Native apps against the instance                  | Nothing server-side                                    | live (untested) |
| API keys                      | Automation + third-party clients                  | —                                                      | live            |

### AI

| Feature                                | What it gives us                                | Needs                                                                                          | State |
| -------------------------------------- | ----------------------------------------------- | ---------------------------------------------------------------------------------------------- | ----- |
| AI connections                         | Provider endpoints + keys, budgeted             | **OpenCode Go** as a direct `openai-chat` connection (no proxy — LiteLLM was removed in #1835) | todo  |
| AI slots `fast` / `careful` / `vision` | Model assignment per role, effort per slot      | OpenCode Go model ids                                                                          | todo  |
| Story guides                           | Per-book AI guides (spoiler-safe)               | Slot `fast`/`careful`, per-feature budget                                                      | todo  |
| Vision scan                            | Identify books from photos of shelves           | Slot `vision` (needs a vision model)                                                           | todo  |
| Reading help                           | In-reader AI assistance                         | Slot `careful`, per-reader caps                                                                | todo  |
| TTS read-aloud                         | Generate narrated audio from epubs              | Separate OpenAI-compatible TTS provider (not the AI slot)                                      | todo  |
| Recommendations (pgvector embeddings)  | "What to read next" from the local catalogue    | Embedding model + backfill job                                                                 | todo  |
| Visual match                           | Cover-based matching against metadata providers | `vision` slot                                                                                  | todo  |

### Metadata

| Feature                             | What it gives us                                                                      | Needs                                         | State                                                                                                      |
| ----------------------------------- | ------------------------------------------------------------------------------------- | --------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Metadata providers                  | goodreads / amazon / openlibrary / itunes (live), Google Books, custom HTTP providers | Keys for the ones that need them              | partial                                                                                                    |
| Bulk metadata fetch                 | 165 books filled in one session, 0 failures                                           | —                                             | live (2026-11-19: 165 covers, 154 descriptions, 135 ISBN-13, avg score 84)                                 |
| Metadata precedence / cache / score | Control which source wins, avoid repeat lookups                                       | Policy decisions                              | partial                                                                                                    |
| Metadata reminders                  | Nag about missing covers/descriptions                                                 | —                                             | todo                                                                                                       |
| File naming + write-back            | Write metadata/cover into the epub, rename files                                      | `fileWrite*` per library, `fileRenameEnabled` | todo (deliberately off)                                                                                    |
| Merge / duplicates / consolidation  | Clean up duplicate records                                                            | —                                             | live — 22 groups merged 2026-11-19 (165 → 142 books), rescan clean, one false-positive group left to prune |
| Custom metadata fields              | Extra facets (shelf, edition, language…)                                              | Definitions                                   | todo                                                                                                       |

### Access, sharing & ops

| Feature                                   | What it gives us                            | Needs                                                         | State     |
| ----------------------------------------- | ------------------------------------------- | ------------------------------------------------------------- | --------- |
| Users, permissions, library access levels | viewer/editor/owner per library             | —                                                             | live      |
| Restrictions (age/content)                | Hide mature libraries from a user           | Rule definitions                                              | todo      |
| Audit log                                 | Who changed what (API-key actions included) | —                                                             | live      |
| Jobs / maintenance page                   | See scans, fetches, stuck work              | —                                                             | live      |
| Notifications (in-app)                    | Scan/request/AI notifications               | —                                                             | live      |
| Server fonts, custom icons, theming       | Cosmetic                                    | —                                                             | live/todo |
| Setup doctor                              | One page showing what is still unwired      | Use before each phase                                         | live      |
| Backups                                   | `/data` via kopiur; DB via CNPG barman      | **Verify** the `bookorbit` DB is in the postgres18 backup set | partial   |
| Gatus + Homepage                          | Probe `/api/v1/health` + tile               | —                                                             | live      |

## Rollout order

1. ~~**Duplicate cleanup**~~ — **done 2026-11-19**, 22 groups merged, rescan clean.
2. **Search & download (built-in sources)** — no infra, no client, fully legal sources first.
3. **Book requests** — auto-approve, destination = dock, notifications; makes the dock earn its keep.
4. **Hardcover** — per-user token, then turn on auto-sync for status/progress/rating.
5. **Search & download (Prowlarr) + download client** — needs the path decision below.
6. **AI via OpenCode Go** — connection → slots → story guides → reading help → vision/recommendations.
7. **Devices**: Kobo (zeli has a Kobo), KOReader, then SMTP for delivery/notifications.
8. **Metadata depth**: precedence, reminders, naming/write-back.
9. **Insight**: Readwise/StoryGraph, collections/smart scopes, achievements, shared reading insights.
10. **Access & ops**: Authentik OIDC, restrictions, backup verification, audit review.
11. **Long tail**: migration importer, visual match, custom icons/fonts, chapter editor.

## Phase detail

### 1. Duplicate cleanup — done 2026-11-19

Scan (`POST /api/v1/book-duplicates/scans {similarityPercent: 90}`) found **22 groups / 23 extra
copies**, 0 `other_format` pairs, all inherited from Grimmory (21 in `Zeli`, 1 in `Brauni`). Match
reasons: `isbn`, `exact_metadata`, `fuzzy_metadata`.

Resolved with `POST /api/v1/book-duplicates/resolutions` →
`{scanId, allGroups: {keepRule: 'metadata', action: 'merge'}, removeIdenticalCopies: true}`:
job 2 processed 22/22 groups, **23/23 merged, 0 failed**, and a fresh scan reports 0 groups.
165 book records → **142** (`Brauni` 74, `Zeli` 68).

Two lessons worth keeping:

- **The first attempt failed 22/22 with `FOLDER_NOT_WRITABLE`.** The merge planner runs `access(folder,
  W_OK)` as the _node_ user (uid 1000), and the library roots had been created by `mkdir` inside the pod
  as root (`root:node 2755`). Always `chown -R 1000:1000 /data/books` after creating directories there.
- **Merge does not delete files** unless they are byte-identical (`removeIdenticalCopies`), and none of
  ours were — the 23 extra epubs were re-pathed _into_ the keeper's book folder as extra files of that
  book. File count stayed 167, so the "37.8 MB reclaimable" was theoretical.
- One group was a **false positive**: `Celestial` (3 files, 2.7MB/1.3MB/1.1MB) where two are
  "Angels of Elysium, Book 2" and the third is a different series entry carrying book 2's ISBN
  (Grimmory metadata bug). All three now hang off one book record; nothing was lost. Prune with
  `DELETE /api/v1/books/files/:fileId` (or the book's file list in the UI) if we want it clean.

Unmerge/split does not exist — `book-merge` only offers `preview` and merge, so a wrong merge is undone
by deleting the surplus files, not by rolling the record back.

### 2. Search & download — built-in sources

BookOrbit ships HTTP-direct indexer plugins, so no download client and no external path sharing is
involved: `project-gutenberg`, `internet-archive`, `librivox`, plus `libgen`/`annas-archive`/`myanonamouse`
(grey sources, opt-in) and the `torznab`/`newznab` adapters for Prowlarr/Jackett.

- Settings → Requests → _Indexers_: add the public-domain sources first, run each one's test.
- Settings → Requests → defaults: which library new grabs file into, format priority, per-request
  destination (`Brauni` for you, `Zeli` for her — requests carry the requester's library).
- Keep the grey sources off until we decide about them explicitly.

### 3. Book requests

- Permissions: `book_request_access` for `zeli`, `book_request_auto_approve` for you.
- Automation: auto-search on request, dedupe against the library ("already in library" check),
  notification on completion, destination folder = library root.
- Decisions: human approval vs auto-approve, request rate limits, what happens when the match is bad
  (park in dock vs discard).

### 4. Hardcover

- Per-user: Settings → Hardcover → paste the Hardcover API token (stored per user in the DB, not in
  Infisical — it is a personal credential, like the Readwise token).
- Then Settings → Hardcover → auto-sync: status, progress, rating; and the initial link pass
  (match by ISBN/ASIN, then title+author, cached).
- Decisions: sync both users or just you; whether BookOrbit is the source of truth for progress or
  Hardcover is.

### 5. Search & download with Prowlarr + a download client (`blocked`)

The hard constraint: **BookOrbit's `/data` is a `ceph-block` RWO claim**. A download client that runs
outside that pod (our SABnzbd/qBittorrent "aio" stack on the host) cannot write into it, and BookOrbit
needs the finished file _inside_ its own tree to import it. Options:

- **(a) Direct HTTP only** — built-in sources download into the dock themselves. No client, no path
  mapping, no egress to the aio host. Loses torrent/usenet breadth.
- **(b) hostPath mount** — pin the bookorbit pod to the aio node and mount the completed-downloads
  directory (like `media/shelfmark` mounts `/aio/remote/infinidysk`), then use BookOrbit's
  path-mapping to translate client paths → `/data/book-dock/…`. Works, but couples the pod to one node
  and puts unwritable-by-1000:1000 host paths in the way.
- **(c) RWX staging volume** — a `ceph-filesystem` PVC the client can also reach; BookOrbit imports
  from it. Needs the client to be a cluster workload (it isn't today).

Recommendation: ship (a) first, decide on (b) vs (c) only if the request flow proves useful.

Also needed for (b)/(c): `/qbittorrent/USERNAME|PASSWORD` or `/sabnzbd/API_KEY` in Infisical, plus a
Cilium egress rule if we start restricting egress.

### 6. AI (OpenCode Go, direct)

LiteLLM is gone from this cluster (holmesgpt already talks to OpenCode Go directly, and #1835 removed
the proxy), so BookOrbit does the same — one less hop, one less budget surface:

| Field    | Value                                                                                                       |
| -------- | ----------------------------------------------------------------------------------------------------------- |
| Name     | `opencode-go`                                                                                               |
| API type | `openai-chat`                                                                                               |
| Base URL | `https://opencode.ai/inference/go/openai/v1` (**Go plan path**; pay-as-you-go is `.../inference`)           |
| API key  | OpenCode Console key — copy of `/holmesgpt/OPENCODE_API_KEY`, kept per-app at `/bookorbit/OPENCODE_API_KEY` |
| Headers  | `x-opencode-session: bookorbit-media` and `User-Agent: bookorbit/3.9.0`                                     |

Verified against the live endpoint on 2026-11-19: `/models` lists **31 chat models**, 24 of them accept
`image/*` input (so the `vision` slot is usable), and `POST /chat/completions` answers with an
OpenAI-shaped body **including `usage`** (the `usage` probe step passes). Two real constraints:

- **`x-opencode-session` is mandatory for chat completions** (`400 MissingSessionID` without it; `/models`
  tolerates its absence, so a connection can test green and still fail on first use). `authorization`,
  `accept`, `content-type` are in `AI_RESERVED_HEADER_NAMES` — BookOrbit sets those itself, so only the
  session header and a User-Agent need adding.
- **Dollar budgets only work if prices are entered.** Go is flat-rate: the response carries
  `usage.cost: 0` with `opencode.billing_source: "go"` (the gateway reports `list_cost` separately,
  e.g. `0.0000183` for a 59-token exchange). `AiModelPrices` is user-supplied, so leave prices empty and
  cap by _builds/requests per month_, or fill in list prices by hand if dollars are wanted.

`/admin/ai` is `@InteractiveOnly()` — API keys are refused, so the connection and the key must be
entered in Settings → Admin → AI. Suggested mapping from the live model list:

- `fast` → `deepseek-v4.1-flash` (image-capable) · alternatively `qwen3.8-flash`, `glm-5.3-flash`
- `careful` → `claude-haiku-5-5`, `gpt-6-luna` or `kimi-k3`
- `vision` → `gemini-4-argon` or `grok-4.7`

Then per feature (Settings → Admin → AI → each of `story-guides`, `vision-scan`, `reading-help`):
budgets, the privacy confirmation on first enable, and the per-reader caps for `perReader` features.
The Go quota is shared with HolmesGPT — story guides are long generations, so keep the per-reader caps
tight at first.

Remaining AI pieces are separate from the connection: **TTS read-aloud** is its own OpenAI-compatible
TTS endpoint (BookOrbit does not route TTS through an AI slot), and **recommendations** need an
embedding model plus a catalogue backfill.

Egress: `bookorbit` → `opencode.ai` over TLS; the Cilium policy is ingress-only, so no rule to add.

## Open decisions

- [ ] Doctrine on grey sources (Libgen/Anna's/MAM) — on, off, or admin-only?
- [ ] Duplicates: prune the `Celestial` false-positive group (3 files on one record), or leave it.
- [ ] Download path strategy (a/b/c above) for torrent/usenet.
- [ ] SMTP: add credentials (unlocks password-reset emails, request notifications, send-to-Kobo/device).
- [ ] Authentik OIDC: adopt SSO for both users, or keep local passwords?
- [ ] Hardcover: one-way (BookOrbit → Hardcover) or bidirectional?
- [ ] AI budget: server-wide cap and per-reader cap (dollar budgets need manually entered model
      prices on the flat-rate Go plan — otherwise only builds/requests caps apply).
- [ ] Metadata write-back to files: keep off (files stay byte-identical to Grimmory) or enable per library?
- [ ] Verify `bookorbit` is inside the CNPG postgres18 backup set; if not, add it before we accumulate real state.
