## Open question: should `fixtures/index.sqlite3` be committed to git?

The index DB is currently gitignored (`fixtures/*.sqlite3` plus the
`-journal`/`-wal`/`-shm` variants in `.gitignore`, rationale: "carries
per-host queue state and fixture history — never committed"). This work
is being handed off to a different environment, so the trade-off is
live.

### Option A — keep gitignored (current; recommended default)

**Pros**

- The `fixtures/*.json` files are the durable, reviewable artifact.
  The daemon lazily backfills `fixtures` rows from any valid committed
  `fixtures/<id>.json`, and `fixtures queue --recipes --available`
  rebuilds the queue + probe state on a fresh machine (~6 min here).
  A new environment fully reconstructs the index with two commands.
- SQLite is binary: diffs are unreadable, and every probe/re-queue
  rewrites the file — noisy, unmergeable commits.
- `queue` rows are per-host by design (`runner` pid, `created_at`,
  `available` probe results, platform).

**Costs**

- No single committed manifest of capture state (`generated_at`,
  `runner`, `harness_version`) — the JSON files carry `trailer`/
  `origin` per fixture but no aggregate index.
- A fresh environment must re-run the availability probe to restore
  `available` flags and the reasonix handoff rows.
- Two environments writing the DB concurrently would conflict.

### Option B — commit a text manifest instead of the binary

Commit a generated `fixtures/manifest.txt` (or `.json`) derived from the
committed `fixtures/*.json`: `harness|provider|model|platform|origin`
per row. Gives the audit + portability with readable, mergeable diffs.
Cost: a small generator step that must stay in sync.

### Option C — commit the binary index

`.gitignore` exception for `fixtures/index.sqlite3`. Exact state handoff
to the receiving environment, at the cost of binary churn in every
commit and per-host noise (runner/created_at/available).

### Decision

Deferred to the receiving environment; the recommended default is
**Option A** (keep `fixtures/*.sqlite3` gitignored). If an aggregate
audit is wanted across environments, prefer **Option B** (text
manifest) over **Option C** (binary DB).
