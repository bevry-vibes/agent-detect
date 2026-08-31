/**
 * `fixtures/.index.json` — the committed state store. TypeScript
 * structure declarations are the SOURCE OF TRUTH for the store's
 * shape (the zig program never imports TypeScript; this file is the
 * normative shape humans and agents read instead of prose). Semantic
 * rules — table ownership, purity, expansion, staleness criteria,
 * crash-resume — stay in DESIGN.md "index.json state store".
 *
 * The store holds ONLY the non-derivable state. Everything else about
 * a fixture lives in the fixture files themselves
 * (`fixtures/from-identity/<id>.json` and
 * `fixtures/from-capture/<id>.json` — see fixtures/fixture.d.ts);
 * the legacy store v1 `fixtures` map and `errors` ledger are dropped
 * on load and never re-serialized. Ledger dates, writer versions,
 * harness versions, hashes (none exist any more), and the curated
 * launch argv all live in the fixture files' `meta`.
 *
 * Null-as-absent: unset optional fields are OMITTED from the store
 * entirely (never serialized as `null`). In this schema, `?:` means
 * exactly "null, expressed as absence"; the reader treats a missing
 * optional as null.
 *
 * Note: the free axis is NOT a store table — membership is declared
 * by `fixtures/.providers_freemodels.csv` (sparse provider×model grid
 * of free model-ids), which the zig program reads at expansion time.
 * Feasibility comes from `fixtures/.harnesses_providers.csv` and
 * `fixtures/.providers_models.csv` (the reference grids — a pair is
 * feasible iff its cell is present and not `-`).
 *
 * All slug keys below are strict slugs: lowercase alphanumeric with
 * no separators ("kimi-code" → "kimicode", "qwen3.8-27b" →
 * "qwen3827b"). Timestamps are Unix epoch seconds.
 */

/** Platforms a daemon can capture on. */
export type Platform = "darwin" | "linux" | "windows";

/** Refresh modes: declared generation vs live capture. */
export type Mode = "from-identity" | "from-capture";

export type HarnessSlug = string;
export type ProviderSlug = string;
export type ModelSlug = string;

/** `<harness>-<provider>-<model>-<platform>`, all strict slugs. */
export type FixtureId = string;

/**
 * The staleness criteria a queue entry carries. A candidate is stale
 * iff ANY carried criterion says stale (OR, short-circuit per
 * candidate); all four absent = a `--refresh` entry (every candidate
 * is worked). Absent evidence (no file, no meta) ⇒ every carried
 * criterion says stale. The CLI `--stale` flag stamps the composite:
 * output-drift OR age 27 days OR harness-version OR detect-version.
 */
export interface StaleCriteria {
  /** the two channel files' outputs.identify not both present and deep-equal. */
  stale_by_output_drift?: boolean;
  /** Age threshold on the mode file's meta.updated_at, in MINUTES. */
  stale_by_minutes?: number;
  /** meta.harness_version differs from a live version_launch probe. */
  stale_by_harness_version?: boolean;
  /** meta.agent_detect_version absent or ≠ this binary's version. */
  stale_by_detect_version?: boolean;
}

/**
 * One queue entry: a filter tuple, not an expanded candidate. The
 * daemon expands at poll time. Constraints (semantic, enforced by
 * the CLI): `--refresh` conflicts with `--stale` and every
 * `--stale-*`; an explicit `--stale-*` forms the criteria set alone;
 * `--stale` plus an explicit `--stale-*` overwrites just that
 * component of the composite; with no staleness flag the full
 * composite is stamped. `free` membership comes from
 * `fixtures/.providers_freemodels.csv`.
 */
export interface QueueEntry extends StaleCriteria {
  harness?: HarnessSlug;
  provider?: ProviderSlug;
  model?: ModelSlug;
  /** Unset = every platform's daemon expands its own candidate. */
  platform?: Platform;
  mode: Mode;
  /** true = members of .providers_freemodels.csv; false = non-members. */
  free?: boolean;
  /** pid of the enqueueing process (provenance lives here only). */
  runner: number;
  /** Stamped on this entry's first expansion work; null until then. */
  started_at?: number;
}

/**
 * The backlog — actionable gaps, derived from folder scans and
 * maintained (idempotent union on write, removed when resolved) by
 * the daemon's pick and `fixtures status`. The three unknown_* sets
 * hold unique dim slugs from unresolvable stems (a fix — adding a
 * rule — is addressable per dim); `needs_curation` holds fixture ids
 * of fixtured from-capture files whose meta lacks prompt_launch.
 * Never null/empty strings; a stem that can't split 4-way attributes
 * no dim and lands in no set (the envelope test flags the file).
 */
export interface Backlog {
  unknown_harnesses?: HarnessSlug[];
  unknown_providers?: ProviderSlug[];
  unknown_models?: ModelSlug[];
  needs_curation?: FixtureId[];
}

/**
 * Retryable operational failures — the failure memory. A flat map of
 * fixture id → truncated, home-path- and key-redacted failure message
 * (stderr tail or the worker's diagnostic). Last failure wins; an
 * entry is removed when any channel of that combo succeeds (the
 * fixture file is the success memory, this is the failure memory).
 * Informational only — pops never gate on it; the dev agent reads the
 * message and handles it. Retry via `fixtures queue --refresh` or a
 * targeted `fixtures queue --repair`.
 */
export type KnownButFailed = Record<FixtureId, string>;

/** The whole `fixtures/.index.json` document. */
export interface IndexStore {
  store_version: 2;
  /** The filter-entry work queue (order = daemon scan order). */
  queue: QueueEntry[];
  /** The actionable gaps (see Backlog). */
  backlog: Backlog;
  /** The retryable failure memory (see KnownButFailed). */
  known_but_failed: KnownButFailed;
}
