# Resumption handoff — macOS and Windows hosts

Written 2026-09-24 on the linux host, after the detached-daemon drain landed the linux corpus
(`1abe86f`). The store and the fixture files sync via git (CONTRIBUTING "cross-device runbook"),
so this file is the state a darwin or windows session should read before starting its daemon.

## Where the corpus stands (after the linux drain)

The sweep's convergence carrier — legacy `raw` retiring per file, `found`/`explain`/`.stderr`
confirmed, the check-reciprocal channels (WS1) and the audited qwen3.8-flash values (WS2) landing —
has run on **linux only**:

- linux from-identity: **995/1165 regenerated**; the other 170 are structurally excluded (see below).
- darwin from-identity: **815 files, none regenerated** — zero carry `found` or the check-reciprocal
  channels; 58 still carry the pre-individuation `provider_id: "ollama"`.
- windows from-identity: **810 files, none regenerated** — same shape; 57 pre-individuation.

## The blocklist exclusion (applies on every host)

`backlog.blocklist` maps git user balupton → [chutes, opencodego, deepseek, hyper, clinepass,
ollamacloud]. The blocklist gates queue expansion in **both modes** (`expandForPlatform`), paid
combos only — a provider with no free-grid rows is fully excluded. None of the six has free rows
except clinepass (its free-grid combos stay workable). So the never-regenerated residue is, per
platform: ollamacloud 95/58/57, opencodego 25/100/100-ish, hyper 21/84/84, chutes 14/56/56,
clinepass (paid) 13/…/…, deepseek 2/…/… (linux/darwin/windows). **The plan
`.plans/1790219820902` WS3 item 1 (the ollamacloud refresh) is a structural no-op**: its queue entry
self-purges with zero candidates everywhere. Those files keep their pre-sweep shape (and the
test-run warnings keep firing) until the user changes the blocklist, adds free-grid rows, or deletes
the stale files (purging is user discretion). Do not re-queue ollamacloud expecting work.

## The queue-entry lesson (why a bare daemon run shows "idle, queue empty")

A queue entry stamps `started_at` on its first work; candidates whose `meta.updated_at` ≥ that stamp
are **done** for that entry. The 13 standing entries carry old stamps, and the earlier declared-raw
regen batches refreshed many files — so on a fresh host the standing entries expand to nothing and
the daemon idles even though `fixtures status` shows staleness (the composite lens is not the entry
done-rule lens). **Each host queues its own fresh sweep**:

```sh
./zig-out/bin/agent-detect-dev fixtures queue --platform=darwin --refresh --from-identity   # on macOS
./zig-out/bin/agent-detect-dev fixtures queue --platform=windows --refresh --from-identity  # on Windows
```

The entry purges itself on completion. Expect roughly 470 workable declarations per darwin/windows
host (the corpus total minus the blocklisted-paid residue) at the 0.25s identity pace — minutes, not
hours.

## Daemon launch per host (DESIGN "user-only daemon" — never in-session)

- **linux** — the agent starts it detached (the agent-started detached run recipe; setsid + the
  marker env vars unset). Done this session.
- **macOS** — the LaunchAgent bootstrap ("daemon launch: macOS LaunchAgent bootstrap"); a plain user
  terminal run is the baseline. Headless ssh can't `launchctl bootstrap` — use a terminal run there.
- **Windows** — the user opens it ("daemon launch: Windows scheduled task (no admin)", or a plain
  terminal): no detached agent spawn exists there, which is exactly the DESIGN carve-out.

The daemon log is the timeline; a pre-capture review window announces every token-consuming
from-capture launch (write `stop` to `fixtures/daemon.ctl` to cancel).

## After the drain

`zig build test` (the byte-stability test reads the renamed `found` channel since `2b68855`), then
the corpus lands as its own `fixtures:` commit (commits.md: build first, generated trailer) and
push. The standing known_but_failed entries (310) clear as their combos succeed; the darwin-capture
failures recorded from wrong-host attempts (the `ioreg` family) are retryable on darwin itself.
`known_but_failed` is informational, never a gate.

## Considerations already stored (not this handoff's work)

Unchanged from `.plans/1790219820902` "Considerations stored for later" — settings visibility,
fixtures-as-a-website, Windows KILL_ON_JOB_OBJECT, the shared `local` rule, kilo sqlite evidence
claims, `pending_binary_names`, contributor-scope items.
