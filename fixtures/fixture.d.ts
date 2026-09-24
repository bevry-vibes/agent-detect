/**
 * `fixtures/from-identity/<id>.json` and `fixtures/from-capture/<id>.json` — the normative schemas for the per-channel fixture files.
 * Each channel is a whole self-contained file under its own directory, owned exclusively by its writer: a writer serializes the entire file and atomically replaces it (temp + rename); there is no merge-write and no store row.
 * A from-capture file is written ONLY on a successful capture — it always carries `outputs` (no meta-only stubs exist).
 * The directory IS the channel — no channel key prefixes inside files.
 *
 * `<id>` is the dash-joined fixture id `<harness>-<provider>-<model>-<platform>`, all strict slugs — the filename is the only channel key, and the dims are never repeated inside the file.
 *
 * Every file has exactly two top-level objects:
 * - `outputs` — the saved outputs of the channel;
 * - `meta` — everything else: ledger dates, writer version, and the invocation of record (from-capture only).
 *
 * Channel presence = file existence — no JSON parse needed to know whether a channel ran.
 * A stem present in both folders has both channels.
 * See fixtures/index.d.ts for the store and DESIGN.md for the semantics.
 */

/** Platforms a daemon can capture on. */
export type Platform = "darwin" | "linux" | "windows";

/** `<harness>-<provider>-<model>-<platform>`, all strict slugs. */
export type FixtureId = string;

/**
 * The 29-field identify contract (`buildCooked` output, frozen by DESIGN.md #9).
 * Grouped by entity: harness, provider, model, then the composed agent fields.
 * The licence fields (`harness_license`, `model_license`) are INFORMATION ONLY — the licence does not gate the determination.
 * The setting fields are instance state with null-as-absent semantics: absent means unset. The scandal flags are explicit booleans (ruling, 2026-09-21): false is visible, not inferred from absence — pre-growth fixtures may lack the keys until their next regeneration.
 * The `*_reciprocity` fields at the entity level are the computed per-entity deductions: true (passes), false (fails), null (undeterminable).
 */
export interface Identify {
  harness_label: string;
  harness_short_title: string | null;
  harness_name: string;
  harness_id: string;
  harness_license: string | null;
  harness_open_training?: "enforced" | "opt-in" | "opt-out" | "never" | "NOASSERTION" | null;
  harness_closed_training?: "enforced" | "opt-in" | "opt-out" | "never" | "NOASSERTION" | null;
  /** the harness setting (instance state, read from a local artifact — harness only; no readable provider setting exists). */
  harness_open_setting?: "enabled" | "disabled" | "NOASSERTION" | null;
  harness_closed_setting?: "enabled" | "disabled" | "NOASSERTION" | null;
  /** true when the rule flags a reciprocity scandal; explicit false otherwise. */
  harness_reciprocity_scandal?: boolean;
  /** the computed per-entity deduction. */
  harness_reciprocity?: boolean | null;
  provider_label: string;
  provider_name: string;
  provider_id: string;
  provider_closed_training: string | null;
  provider_open_training: string | null;
  provider_reciprocity_scandal?: boolean;
  provider_reciprocity?: boolean | null;
  model_label: string;
  model_short_title: string | null;
  model_name: string;
  model_id: string;
  /** the openness tier of the weights — the former `model_reciprocity` field, renamed; the freed name is the computed deduction below. */
  model_openness: string | null;
  /** what the model selection trains (model-intrinsic serving arrangements; independent of the openness). */
  model_open_training?: string | null;
  model_closed_training?: string | null;
  model_license: string | null;
  model_reciprocity?: boolean | null;
  agent_id: string;
  reciprocal: boolean;
}

/**
 * The shapeless runtime observations block (the dev `raw` output verbatim).
 * Keys: `platform_id`, `harness_version` (the live version snapshot — null when not yet knowable), `detectable` + `detected`, `process_lineage`, the `*-urls` arrays, and `evidence`.
 * Env-source claims on non-allowlisted env vars carry the literal `"<redacted>"`.
 */
export interface Raw {
  platform_id: Platform;
  harness_version?: string | null;
  detectable: string[];
  detected: string[];
  process_lineage: { pid: number; name: string }[];
  "harness-urls": string[];
  "provider-urls": string[];
  "model-urls": string[];
  /** the scandal citations of the matched rules — a flagged rule always carries its sources. */
  "scandal-urls": string[];
  evidence: {
    dim: string;
    source: string;
    name: string;
    field?: string;
    value?: string;
  }[];
}

/** The DECLARED raw block — the from-identity channel's `outputs.raw` (ruling, 2026-09-21).
 *  A declared fixture observed nothing, so the instance-only fields (platform_id, harness_version, process_lineage, evidence) are absent;
 *  what ships is exactly what the rules assert: the dimension arrays and the four source arrays backing every rule-derived identify field. */
export interface DeclaredRaw {
  detectable: string[];
  detected: string[];
  "harness-urls": string[];
  "provider-urls": string[];
  "model-urls": string[];
  "scandal-urls": string[];
}

/** The explain report (`buildExplain` output — why the determination resolved as it did, with remediation actions).
 *  `state` is kebab-cased; `identity` carries the canonical ids only (no agent_id — it stays derivable from the trio);
 *  each reason carries its judged `values` inline, `sources` when citable, and `actions` ({kind kebab-cased, instruction, command?, url?}). */
export interface Explain {
  state: "reciprocal" | "not-reciprocal" | "unknown" | "undetectable";
  identity: { harness: string | null; provider: string | null; model: string | null };
  reasons: {
    entity: "harness" | "provider" | "model";
    code: string;
    values?: { name: string; value: string }[];
    summary: string;
    sources?: string[];
    actions?: { kind: string; instruction: string; command?: string; url?: string }[];
  }[];
}

/**
 * The stderr an action would print for the recorded state, as newline-split line arrays (never multiline strings — arrays read better in JSON).
 * Absent when the action printed no stderr (the clean states).
 */
export type StderrLines = string[];

/** Declared-identification file (from-identity worker; zero tokens).
 *  Always carries `outputs` — there is no meta-only identity stub.
 *  Pre-declared-raw files lack `outputs.raw` until their next regeneration (decision #16). */
export interface IdentityFile {
  outputs: {
    identify: Identify;
    "trailer co-author": string;
    "trailer assisted-by": string;
    /** legacy key — files carry it until their next regeneration sweep (the found rename); the validator accepts both, writers emit only `found`. */
    raw?: DeclaredRaw;
    found?: DeclaredRaw;
    explain?: Explain;
    "identify.stderr"?: StderrLines;
    "explain.stderr"?: StderrLines;
  };
  meta: {
    /** was identity.declared_at — the channel WAS the declaration. */
    updated_at: number;
  };
}

/**
 * Live-capture file (`fixtures capture` in a real session, or the daemon's from-capture worker) — written only on success, so `outputs` is always present.
 * Authored invocations for not-yet-captured combos live in the store's `invocations` table (see fixtures/index.d.ts), never in a stub file.
 */
export interface CaptureFile {
  outputs: {
    identify: Identify;
    "trailer co-author": string;
    "trailer assisted-by": string;
    /** legacy key — files carry it until their next re-capture (the found rename); the validator accepts both, writers emit only `found`. */
    raw: Raw;
    found?: Raw;
    explain?: Explain;
    "identify.stderr"?: StderrLines;
    "explain.stderr"?: StderrLines;
  };
  meta: {
    /** was capture.captured_at. */
    updated_at: number;
    /**
     * was capture.harness_version — the live version snapshot from the `version_invocation` probe. REQUIRED: a capture that cannot record it fails and writes no file.
     */
    harness_version: string;
    /**
     * The invocation of record — the launch argv that ran `fixtures capture` inside this live session.
     * argv[0] is the concrete per-platform binary; the last element is the capture prompt placeholder `<prompt>` (see `fixtures prompt`).
     * Minimal invocation: only the arguments necessary to pin harness + provider + model and run the capture prompt (see CONTRIBUTING.md "minimal invocation").
     * REQUIRED — from-capture only gets fully programmatically-invokable captures: a capture with no invocation of record (store table or replaced file) fails and writes no file, so a committed from-capture file always carries the complete invocation.
     */
    prompt_invocation: string[];
    /** e.g. ["kimi", "--version"] — availability probe + version source. REQUIRED (see `prompt_invocation`). */
    version_invocation: string[];
  };
}
