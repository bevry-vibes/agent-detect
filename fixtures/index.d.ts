/**
 * `fixtures/index.json` — the committed state store. TypeScript
 * structure declarations are the SOURCE OF TRUTH for the store's
 * shape (the zig program never imports TypeScript; this file is the
 * normative shape humans and agents read instead of prose). Semantic
 * rules — table ownership, purity, expansion, staleness criteria,
 * crash-resume — stay in DESIGN.md "the state split".
 *
 * The store holds ONLY the non-derivable state. Everything else about
 * a fixture lives in the fixture files themselves
 * (`fixtures/from-identity/<id>.json` and
 * `fixtures/from-capture/<id>.json` — see fixtures/fixture.d.ts);
 * the legacy store v1 `fixtures` map and `errors` ledger, and the v2
 * top-level `known_but_failed`, are dropped on load and never
 * re-serialized. Ledger dates, writer versions, harness versions, and
 * the invocation of record all live in the fixture files' `meta`.
 *
 * Null-as-absent: unset optional fields are OMITTED from the store
 * entirely (never serialized as `null`). In this schema, `?:` means
 * exactly "null, expressed as absence"; the reader treats a missing
 * optional as null.
 *
 * Note: the free axis is NOT a store table — membership is declared
 * by `fixtures/providers-freemodels.csv` (sparse provider×model grid
 * of free model-ids), which the zig program reads at expansion time.
 * Feasibility comes from `fixtures/harnesses-providers.csv` and
 * `fixtures/providers-models.csv` (the reference grids — a pair is
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
 * candidate); all five absent = a `--refresh` entry (every candidate
 * is worked). Absent evidence (no file, no meta) ⇒ every carried
 * criterion says stale. The CLI `--stale` flag stamps the composite:
 * output OR age 27 days OR harness-version OR detect-version OR
 * invocation.
 */
export interface StaleCriteria {
  /** the two channel files' outputs.identify not both present and deep-equal. */
  stale_by_output?: boolean;
  /** Age threshold on the mode file's meta.updated_at, in MINUTES. */
  stale_by_minutes?: number;
  /** meta.harness_version differs from a live version_invocation probe. */
  stale_by_harness_version?: boolean;
  /** meta.agent_detect_version absent or ≠ this binary's version. */
  stale_by_detect_version?: boolean;
  /** The file's recorded invocation is missing or differs from the
   *  latest one in the invocations table (from-capture only). */
  stale_by_invocation?: boolean;
}

/**
 * One queue entry: a filter tuple, not an expanded candidate. The
 * daemon expands at poll time. Constraints (semantic, enforced by
 * the CLI): `--refresh` conflicts with `--stale` and every
 * `--stale-*`; an explicit `--stale-*` forms the criteria set alone;
 * `--stale` plus an explicit `--stale-*` overwrites just that
 * component of the composite; with no staleness flag the full
 * composite is stamped. `free` membership comes from
 * `fixtures/providers-freemodels.csv`.
 */
export interface QueueEntry extends StaleCriteria {
  harness?: HarnessSlug;
  provider?: ProviderSlug;
  model?: ModelSlug;
  /** Unset = every platform's daemon expands its own candidate. */
  platform?: Platform;
  mode: Mode;
  /** true = members of providers-freemodels.csv; false = non-members. */
  free?: boolean;
  /** pid of the enqueueing process (provenance lives here only). */
  runner: number;
  /** Stamped on this entry's first expansion work; null until then. */
  started_at?: number;
}

/**
 * The backlog — actionable gaps + the failure memory, derived from
 * folder scans and maintained (idempotent union on write, removed
 * when resolved) by the daemon's pick and `fixtures status`. The
 * three unknown_* dim sets hold unique dim slugs from unresolvable
 * stems (folder stems and invocations-table ids alike — a fix, adding
 * a rule, is addressable per dim); `unknown_invocations` holds fixture
 * ids of from-capture files with no invocation of record anywhere (the
 * signal to the dev agent that rules/argv are still needed for a
 * successful re-capture). `known_but_failed` is the retryable failure
 * memory. Never null/empty strings; a stem that can't split 4-way
 * attributes no dim and lands in no set (the envelope test flags the
 * file).
 */
export interface Backlog {
  unknown_harnesses?: HarnessSlug[];
  unknown_providers?: ProviderSlug[];
  unknown_models?: ModelSlug[];
  unknown_invocations?: FixtureId[];
  /**
   * Retryable operational failures — flat id → truncated,
   * home-path- and key-redacted failure message (stderr tail or the
   * worker's diagnostic). Last failure wins; an entry is removed when
   * any channel of that combo succeeds (the fixture file is the
   * success memory, this is the failure memory). Informational only —
   * pops never gate on it; the dev agent reads the message and
   * handles it. Retry via `fixtures queue --refresh` or a targeted
   * `fixtures queue --repair`.
   */
  known_but_failed: Record<FixtureId, string>;
}

/**
 * The authored invocations — the dev agent's signal for what should
 * capture (rules/etc needed for a successful capture). Zig reads this
 * table ONLY to handle pop (the launch argv + version probe; the table
 * entry wins over the file's recorded meta as "the latest") and
 * `--repair` (an unknown_invocations item that gains an entry re-queues
 * as a targeted from-capture entry). Keyed by FixtureId. A successful
 * capture records the invocation it ran under into the fixture file's
 * own `meta` (see fixtures/fixture.d.ts); the table entry persists as
 * the re-capture source.
 */
export interface Invocations {
  [fixtureId: FixtureId]: {
    /**
     * Launch argv that runs `fixtures capture` inside a live session.
     * argv[0] is the concrete per-platform binary; the last element is
     * the capture prompt placeholder `<prompt>` (see
     * `fixtures prompt`). Minimal invocation: only the arguments
     * necessary to pin harness + provider + model and run the capture
     * prompt (see CONTRIBUTING.md "minimal invocation").
     */
    prompt_invocation: string[];
    /** e.g. ["kimi", "--version"] — availability probe + version source. */
    version_invocation?: string[];
  };
}

/** The whole `fixtures/index.json` document. */
export interface IndexStore {
  store_version: 3;
  /** The filter-entry work queue (order = daemon scan order). */
  queue: QueueEntry[];
  /** The actionable gaps + failure memory (see Backlog). */
  backlog: Backlog;
  /** The authored invocations (see Invocations). */
  invocations: Invocations;
}
