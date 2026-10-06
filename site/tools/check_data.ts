// tools/check_data.ts — the drift alarm: validates every data file the site
// serves (and the committed state it derives from) against
// site/src/lib/schemas.ts, and asserts the cross-checks the schemas can't
// state themselves:
//   D4 — agents.json is authoritative for per-agent platforms/reciprocal; the
//        committed index's agent_map_to_platforms_reciprocal is derived and
//        must agree — and both must agree with the fixture store itself
//        (platforms == the from-capture stems, scanned never parsed;
//        reciprocal/state/email/updated_at == the agent's from-identity
//        declaration).
//   D5 — the runtime Identify/IdentityFile schemas stay field-identical to
//        fixtures/fixture.d.ts (the frozen 29-field contract): the key sets
//        are parsed out of the d.ts and compared.
// Wired into `deno task check` — a failure fails the build.

import { join, fromFileUrl } from "@std/path";
import {
  AgentsFileSchema,
  IdentifySchema,
  IdentityFileSchema,
  IndexDataFileSchema,
  RegistryFileSchema,
  FixtureOutputsSchema,
  type AgentRow,
} from "../src/lib/schemas.ts";

const siteDir = fromFileUrl(new URL("../", import.meta.url));
const repoDir = fromFileUrl(new URL("../../", import.meta.url));
const dataDir = join(siteDir, "public/data");

const PLATFORMS = ["darwin", "linux", "windows"];

let failures = 0;
function fail(msg: string) {
  failures += 1;
  console.error(`check_data: ${msg}`);
}

function readJson(p: string): unknown {
  return JSON.parse(Deno.readTextFileSync(p));
}

// ── 1. the served data files ────────────────────────────────────────────────

const registryRaw = readJson(join(dataDir, "registry.json"));
const servedIndexRaw = readJson(join(dataDir, "index.json"));
const agentsFileRaw = readJson(join(dataDir, "agents.json"));
const registry = RegistryFileSchema.parse(registryRaw);
const indexData = IndexDataFileSchema.parse(servedIndexRaw);
const agentsFile = AgentsFileSchema.parse(agentsFileRaw);

// every per-agent document is the from-identity fixture verbatim
for await (const ent of Deno.readDir(join(dataDir, "agents"))) {
  if (!ent.isFile || !ent.name.endsWith(".json")) continue;
  IdentityFileSchema.parse(readJson(join(dataDir, "agents", ent.name)));
}

// the committed index the released cli embeds — the same shape
IndexDataFileSchema.parse(readJson(join(repoDir, "fixtures/index-data.json")));

// every from-identity fixture validates against the identity contract
const identityDir = join(repoDir, "fixtures/from-identity");
const identityFiles = new Map<string, Record<string, unknown>>();
for await (const ent of Deno.readDir(identityDir)) {
  if (!ent.isFile || !ent.name.endsWith(".json")) continue;
  const stem = ent.name.slice(0, -".json".length);
  const parsed = readJson(join(identityDir, ent.name)) as Record<string, unknown>;
  IdentityFileSchema.parse(parsed);
  identityFiles.set(stem, parsed);
}

// ── 2. D4 — authority: agents.json ↔ the index map ↔ the store itself ──────

// platforms == the from-capture stems (scanned, never parsed)
const captureDir = join(repoDir, "fixtures/from-capture");
const capturePlatforms = new Map<string, Set<string>>();
for await (const ent of Deno.readDir(captureDir)) {
  if (!ent.isFile || !ent.name.endsWith(".json")) continue;
  const stem = ent.name.slice(0, -".json".length);
  const parts = stem.split("-");
  const plat = parts.pop();
  if (parts.length < 3 || !PLATFORMS.includes(plat!)) fail(`from-capture stem ${stem} is not a 4-part fixture id`);
  else {
    const set = capturePlatforms.get(parts.join("-")) ?? new Set<string>();
    set.add(plat!);
    capturePlatforms.set(parts.join("-"), set);
  }
}

const agentMap = indexData.agent_map_to_platforms_reciprocal;
const rowsByAgent = new Map<string, AgentRow>(agentsFile.agents.map((r) => [r.agent_id, r]));
const agentIds = [...identityFiles.keys()].sort();

if (agentsFile.agents.length !== agentIds.length) {
  fail(`agents.json has ${agentsFile.agents.length} rows but the from-identity channel holds ${agentIds.length} files`);
}
if (Object.keys(agentMap).length !== agentIds.length) {
  fail(`the index's agent map holds ${Object.keys(agentMap).length} agents but the channel holds ${agentIds.length}`);
}

const expect = (cond: boolean, msg: string) => {
  if (!cond) fail(msg);
};

for (const agentId of agentIds) {
  const row = rowsByAgent.get(agentId);
  expect(row != null, `agents.json lacks a row for ${agentId}`);
  const mapEntry = agentMap[agentId];
  expect(mapEntry != null, `the index agent map lacks ${agentId}`);
  if (!row || !mapEntry) continue;

  const captured = [...(capturePlatforms.get(agentId) ?? [])].sort();
  expect(
    JSON.stringify(row.platforms) === JSON.stringify(captured),
    `${agentId}: agents.json platforms [${row.platforms}] != the capture stems [${captured}]`,
  );
  expect(
    JSON.stringify(mapEntry.platforms) === JSON.stringify(captured),
    `${agentId}: index map platforms [${mapEntry.platforms}] != the capture stems [${captured}]`,
  );

  const outputs = (identityFiles.get(agentId)!.outputs ?? {}) as Record<string, unknown>;
  const identify = (outputs.identify ?? {}) as Record<string, unknown>;
  const explain = (outputs.explain ?? null) as { state?: string } | null;
  const declaredReciprocal = identify.reciprocal === true;
  const declaredState = (explain?.state as string) ?? null;
  const trailer = (outputs["trailer co-author"] as string) ?? (outputs["trailer assisted-by"] as string) ?? "";
  const declaredEmail = /<([^<>]+)>/.exec(trailer)?.[1] ?? `${agentId}@local`;
  const declaredUpdatedAt = (identityFiles.get(agentId)!.meta as Record<string, unknown>).updated_at as number;
  const free = ((indexData.provider_map_to_free_models[row.provider] ?? []) as string[]).includes(row.model);

  expect(row.reciprocal === declaredReciprocal, `${agentId}: agents.json reciprocal != the declaration`);
  expect(mapEntry.reciprocal === declaredReciprocal, `${agentId}: index map reciprocal != the declaration`);
  expect(row.state === declaredState, `${agentId}: agents.json state != the declaration`);
  expect(row.email === declaredEmail, `${agentId}: agents.json email != the declaration`);
  expect(row.updated_at === declaredUpdatedAt, `${agentId}: agents.json updated_at != the declaration`);
  expect(row.free === free, `${agentId}: agents.json free != the free axis`);

  // the row's dims are the filename's dims
  const [h, p] = agentId.split("-");
  const m = agentId.slice(h.length + p.length + 2);
  expect(row.harness === h && row.provider === p && row.model === m, `${agentId}: row dims != the filename's dims`);
  expect(
    identify.agent_id === agentId,
    `${agentId}: the declaration's identify.agent_id is ${identify.agent_id}`,
  );
}

for (const agentId of Object.keys(agentMap)) {
  expect(identityFiles.has(agentId), `the index agent map has ${agentId} but the channel has no declaration`);
}
for (const agentId of rowsByAgent.keys()) {
  expect(identityFiles.has(agentId), `agents.json has ${agentId} but the channel has no declaration`);
}

// the index copy the site serves is the committed file — compared pre-parse:
// zod's parse reorders keys to schema order, which would mask real drift
const committedIndex = readJson(join(repoDir, "fixtures/index-data.json"));
expect(
  JSON.stringify(servedIndexRaw) === JSON.stringify(committedIndex),
  "data/index.json != fixtures/index-data.json — regenerate with `deno task data`",
);

// ── 3. D5 — the runtime schemas stay field-identical to fixture.d.ts ───────

const dts = Deno.readTextFileSync(join(repoDir, "fixtures/fixture.d.ts"));

/** the key set of a `{ ... }` block found after `anchor`, one declaration per line */
function blockKeys(source: string, anchor: string): Set<string> {
  const at = source.indexOf(anchor);
  if (at === -1) throw new Error(`fixture.d.ts: cannot find ${anchor}`);
  const open = source.indexOf("{", at);
  let depth = 0;
  let end = open;
  for (let i = open; i < source.length; i++) {
    if (source[i] === "{") depth++;
    else if (source[i] === "}") {
      depth--;
      if (depth === 0) {
        end = i;
        break;
      }
    }
  }
  const body = source.slice(open + 1, end);
  const keys = new Set<string>();
  for (const m of body.matchAll(/"([a-z .-]+)"\??:|(\b[a-z_][a-z0-9_]*)\??:/gm)) {
    keys.add(m[1] ?? m[2]!);
  }
  return keys;
}

const dtsIdentify = blockKeys(dts, "export interface Identify {");
const schemaIdentify = new Set(Object.keys(IdentifySchema.shape));
for (const k of dtsIdentify) {
  if (!schemaIdentify.has(k)) fail(`fixture.d.ts Identify has key ${k} the runtime schema lacks`);
}
for (const k of schemaIdentify) {
  if (!dtsIdentify.has(k)) fail(`the runtime Identify schema has key ${k} fixture.d.ts lacks`);
}

const dtsOutputs = blockKeys(dts, "outputs: {");
const schemaOutputs = new Set(Object.keys(FixtureOutputsSchema.shape));
for (const k of dtsOutputs) {
  if (!schemaOutputs.has(k)) fail(`fixture.d.ts IdentityFile.outputs has key ${k} the runtime schema lacks`);
}
for (const k of schemaOutputs) {
  if (!dtsOutputs.has(k)) fail(`the runtime outputs schema has key ${k} fixture.d.ts lacks`);
}

// ── verdict ─────────────────────────────────────────────────────────────────

if (failures > 0) {
  console.error(`check_data: ${failures} failure(s) — the data and the schemas disagree`);
  Deno.exit(1);
}
console.log(
  `check_data: ok — registry (${registry.harnesses.length}/${registry.providers.length}/${registry.models.length}), ` +
    `index (${indexData.harnesses.length} entries), agents (${agentsFile.agents.length}, ` +
    `${identityFiles.size} declarations), D4 + D5 agree`,
);
