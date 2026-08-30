/**
 * `fixtures/.index.json` — the committed state store. TypeScript
 * structure declarations are the SOURCE OF TRUTH for the store's
 * shape (the zig program never imports TypeScript; this file is the
 * normative shape humans and agents read instead of prose). Semantic
 * rules — table ownership, purity, expansion, staleness markers,
 * crash-resume — stay in DESIGN.md "index.json state store".
 *
 * Null-as-absent: unset optional fields are OMITTED from the store
 * entirely (never serialized as `null`). In this schema, `?:` means
 * exactly "null, expressed as absence"; the reader treats a missing
 * optional as null.
 *
 * Note: the free axis is NOT a store table any more — membership is
 * declared by `fixtures/.providers_freemodels.csv` (sparse
 * provider×model grid of free model-ids), which the zig program
 * reads at expansion time. The legacy `free_provider_to_model` table
 * is dropped on load and never re-serialized.
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

/** Declared-identification ledger (from-identity worker). */
export interface IdentityLedger {
  declared_at?: number;
  /** BLAKE3 of the whole `from-identity` channel object in the file. */
  channel_hash?: string;
}

/** Live-capture ledger (capture / from-capture worker). */
export interface CaptureLedger {
  captured_at?: number;
  /** BLAKE3 of the whole `from-capture` channel object in the file. */
  channel_hash?: string;
  /** Harness version observed at capture time. */
  harness_version?: string;
}

/** One row of the known universe: an agent identity on a platform. */
export interface FixtureRow {
  /**
   * Launch argv that runs `fixtures capture` inside a live session.
   * argv[0] is the concrete per-platform binary; the last element is
   * the capture prompt placeholder `<prompt>`.
   */
  prompt_launch?: string[];
  /** e.g. ["kimi", "--version"] — availability probe + version source. */
  version_launch?: string[];
  /** pid recorded by the writer (runner provenance). */
  runner?: number;
  /** agent-detect version whose rules/hashing produced this row. */
  agent_detect_version?: string;
  identity?: IdentityLedger;
  capture?: CaptureLedger;
  /** BLAKE3 of the committed fixture file. */
  fixture_hash?: string;
}

/** One entry of the failure ledger (keyed by FixtureId). */
export interface ErrorEntry {
  reason: string;
  /** Completion timestamp — crash-resume and done-rule input. */
  failed_at: number;
}

/**
 * One queue entry: a filter tuple, not an expanded candidate. The
 * daemon expands at poll time. Constraints (semantic, enforced by
 * the CLI): at most one `stale_by_*` marker; marker sweeps require
 * `known: true`; `valid`/`successful`/`free` default to unset (their
 * expansion defaults are in DESIGN.md; `free` membership comes from
 * `fixtures/.providers_freemodels.csv`).
 */
export interface QueueEntry {
  harness?: HarnessSlug;
  provider?: ProviderSlug;
  model?: ModelSlug;
  /** Unset = every platform's daemon expands its own candidate. */
  platform?: Platform;
  mode: Mode;
  stale_by_missing_entry?: boolean;
  stale_by_missing_fixture?: boolean;
  /** Age threshold, stored in MINUTES, checked per mode-scoped ledger date. */
  stale_by_minutes?: number;
  stale_by_harness_version?: boolean;
  stale_by_detect_version?: boolean;
  stale_by_fixture_hash?: boolean;
  stale_by_channel_hash?: boolean;
  /** true = the fixtures map; false = rule cross-product minus known. */
  known?: boolean;
  /** true = exclude invalid-class errors; false = re-evaluate them. */
  valid?: boolean;
  /** true = no-error candidates only; false = unsuccessful-class only. */
  successful?: boolean;
  /** true = members of .providers_freemodels.csv; false = non-members. */
  free?: boolean;
  /** pid of the enqueueing process. */
  runner: number;
  /** Stamped on this entry's first expansion work; null until then. */
  started_at?: number;
}

/** The whole `fixtures/.index.json` document. Three tables — the free
 *  axis is declared by fixtures/.providers_freemodels.csv, not here
 *  (the legacy `free_provider_to_model` table is dropped at load). */
export interface IndexStore {
  store_version: 1;
  /** The known universe. */
  fixtures: Record<FixtureId, FixtureRow>;
  /** The failure ledger. */
  errors: Record<FixtureId, ErrorEntry>;
  /** The filter-entry work queue (order = daemon scan order). */
  queue: QueueEntry[];
}
