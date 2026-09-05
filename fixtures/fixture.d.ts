/**
 * `fixtures/from-identity/<id>.json` and
 * `fixtures/from-capture/<id>.json` — the normative schemas for the
 * per-channel fixture files. Each channel is a whole self-contained
 * file under its own directory, owned exclusively by its writer: a
 * writer serializes the entire file and atomically replaces it
 * (temp + rename); there is no merge-write and no store row. A
 * from-capture file is written ONLY on a successful capture — it
 * always carries `outputs` (no meta-only stubs exist). The directory
 * IS the channel — no channel key prefixes inside files.
 *
 * `<id>` is the dash-joined fixture id
 * `<harness>-<provider>-<model>-<platform>`, all strict slugs — the
 * filename is the only channel key, and the dims are never repeated
 * inside the file.
 *
 * Every file has exactly two top-level objects:
 * - `outputs` — the saved outputs of the channel;
 * - `meta` — everything else: ledger dates, writer version, and the
 *   invocation of record (from-capture only).
 *
 * Channel presence = file existence — no JSON parse needed to know
 * whether a channel ran. A stem present in both folders has both
 * channels. See fixtures/index.d.ts for the store and DESIGN.md for
 * the semantics.
 */

/** Platforms a daemon can capture on. */
export type Platform = "darwin" | "linux" | "windows";

/** `<harness>-<provider>-<model>-<platform>`, all strict slugs. */
export type FixtureId = string;

/**
 * The 20-field identify contract — the canonical identification
 * object (`buildCooked` output, frozen by DESIGN.md). Grouped by
 * entity: harness, provider, model, then the composed agent fields.
 * The policy fields (harness_license, harness_open_training,
 * harness_closed_training, model_reciprocity,
 * provider_closed_training, provider_open_training) may be `null`.
 * The two harness-training fields are optional only during the
 * keyset-growth transition — pre-growth fixtures regenerate via the
 * stale-by-output sweeps; new files always carry them.
 */
export interface Identify {
  harness_label: string;
  harness_short_title: string | null;
  harness_name: string;
  harness_id: string;
  harness_license: string | null;
  harness_open_training?: "enforced" | "opt-in" | "opt-out" | "never" | "NOASSERTION" | null;
  harness_closed_training?: "enforced" | "opt-in" | "opt-out" | "never" | "NOASSERTION" | null;
  provider_label: string;
  provider_name: string;
  provider_id: string;
  provider_closed_training: string | null;
  provider_open_training: string | null;
  model_label: string;
  model_short_title: string | null;
  model_name: string;
  model_id: string;
  model_reciprocity: string | null;
  model_license: string | null;
  agent_id: string;
  reciprocal: boolean;
}

/**
 * The shapeless runtime observations block (the dev `raw` output
 * verbatim). Keys: `platform_id`, `harness_version` (the live version
 * snapshot — null when not yet knowable), `detectable` + `detected`,
 * `process_lineage`, the `*-urls` arrays, and `evidence`. Env-source
 * claims on non-allowlisted env vars carry the literal `"<redacted>"`.
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
  evidence: {
    dim: string;
    source: string;
    name: string;
    field?: string;
    value?: string;
  }[];
}

/** Declared-identification file (from-identity worker; zero tokens).
 *  Always carries `outputs` — there is no meta-only identity stub. */
export interface IdentityFile {
  outputs: {
    identify: Identify;
    "trailer co-author": string;
    "trailer assisted-by": string;
  };
  meta: {
    /** was identity.declared_at — the channel WAS the declaration. */
    updated_at: number;
  };
}

/**
 * Live-capture file (`fixtures capture` in a real session, or the
 * daemon's from-capture worker) — written only on success, so `outputs`
 * is always present. Authored invocations for not-yet-captured combos
 * live in the store's `invocations` table (see fixtures/index.d.ts),
 * never in a stub file.
 */
export interface CaptureFile {
  outputs: {
    identify: Identify;
    "trailer co-author": string;
    "trailer assisted-by": string;
    /** the raw observations block, verbatim. */
    raw: Raw;
  };
  meta: {
    /** was capture.captured_at. */
    updated_at: number;
    /**
     * was capture.harness_version — the live version snapshot from the
     * `version_invocation` probe. REQUIRED: a capture that cannot
     * record it fails and writes no file.
     */
    harness_version: string;
    /**
     * The invocation of record — the launch argv that ran `fixtures
     * capture` inside this live session. argv[0] is the concrete
     * per-platform binary; the last element is the capture prompt
     * placeholder `<prompt>` (see `fixtures prompt`). Minimal
     * invocation: only the arguments necessary to pin harness +
     * provider + model and run the capture prompt (see
     * CONTRIBUTING.md "minimal invocation"). REQUIRED — from-capture
     * only gets fully programmatically-invokable captures: a capture
     * with no invocation of record (store table or replaced file)
     * fails and writes no file, so a committed from-capture file
     * always carries the complete invocation.
     */
    prompt_invocation: string[];
    /** e.g. ["kimi", "--version"] — availability probe + version source. REQUIRED (see `prompt_invocation`). */
    version_invocation: string[];
  };
}
