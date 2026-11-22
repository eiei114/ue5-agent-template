#!/usr/bin/env node
// Read-only helper for the "saved value vs effective value" split (docs/02-runtime.md, DOT-3240).
//
// It never calls a model, never authenticates, never reads settings.json, auth files or the whole
// environment. Two modes:
//
//   --observe
//       Print the effective values the Pi harness injected into this shell
//       (PI_PROVIDER / PI_MODEL / PI_REASONING_LEVEL). PI_SESSION_* is never printed.
//
//   --model <provider/id> --level <level> [--catalog-dir <dir>]
//       Predict which level the harness will actually use when <level> is requested. The rule is a copy of
//       @earendil-works/pi-ai getSupportedThinkingLevels / clampThinkingLevel (verified against pi-ai 1.5.0):
//       a level the model does not support is replaced by the nearest supported level searching UPWARD
//       first, then downward. The catalog is the pi-ai provider data (dist/providers/data/*.json).
//
// Exit: 0 requested == effective (or --observe succeeded) / 1 requested != effective /
//       2 UNVERIFIED (no node-visible catalog, unknown model, unreadable catalog, not in a Pi session).
//       UNVERIFIED is never a pass.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const THINKING_LEVELS = ['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'];

export class CatalogError extends Error {}

export function getSupportedThinkingLevels(model) {
  if (!model.reasoning) return ['off'];
  return THINKING_LEVELS.filter((level) => {
    const mapped = model.thinkingLevelMap?.[level];
    if (mapped === null) return false;
    if (level === 'xhigh' || level === 'max') return mapped !== undefined;
    return true;
  });
}

export function clampThinkingLevel(model, level) {
  const available = getSupportedThinkingLevels(model);
  if (available.includes(level)) return level;
  const requestedIndex = THINKING_LEVELS.indexOf(level);
  if (requestedIndex === -1) return available[0] ?? 'off';
  for (let i = requestedIndex; i < THINKING_LEVELS.length; i++) {
    if (available.includes(THINKING_LEVELS[i])) return THINKING_LEVELS[i];
  }
  for (let i = requestedIndex - 1; i >= 0; i--) {
    if (available.includes(THINKING_LEVELS[i])) return THINKING_LEVELS[i];
  }
  return available[0] ?? 'off';
}

export function resolveEffort(model, requested) {
  const supported = getSupportedThinkingLevels(model);
  const effective = clampThinkingLevel(model, requested);
  const known = THINKING_LEVELS.includes(requested);
  let relation = 'same';
  if (!known) relation = 'unknown-level';
  else if (effective !== requested) {
    relation = THINKING_LEVELS.indexOf(effective) > THINKING_LEVELS.indexOf(requested) ? 'up' : 'down';
  }
  return { requested, effective, supported, relation, match: known && effective === requested };
}

// A provider file is { <api>: { "<type>:<id>": model } }. The file name is the provider when a model omits it.
export function flattenCatalog(fileProvider, parsed) {
  const models = [];
  if (parsed === null || typeof parsed !== 'object') throw new CatalogError('catalog file is not an object');
  for (const group of Object.values(parsed)) {
    if (group === null || typeof group !== 'object') continue;
    for (const model of Object.values(group)) {
      if (model && typeof model === 'object' && typeof model.id === 'string') {
        models.push({ ...model, provider: model.provider ?? fileProvider });
      }
    }
  }
  return models;
}

export function findModel(models, provider, id) {
  return models.find((m) => m.provider === provider && m.id === id) ?? null;
}

export function loadCatalogDir(dir) {
  let entries;
  try {
    entries = fs.readdirSync(dir).filter((f) => f.endsWith('.json') && !f.startsWith('.'));
  } catch (e) {
    throw new CatalogError(`catalog directory is not readable: ${dir}`);
  }
  if (entries.length === 0) throw new CatalogError(`catalog directory has no provider json: ${dir}`);
  const models = [];
  for (const file of entries) {
    try {
      const parsed = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
      models.push(...flattenCatalog(path.basename(file, '.json'), parsed));
    } catch (e) {
      throw new CatalogError(`catalog file is not valid: ${file}`);
    }
  }
  let structureHash = null;
  try {
    structureHash = JSON.parse(fs.readFileSync(path.join(dir, '.manifest.json'), 'utf8')).structureHash ?? null;
  } catch { /* the manifest is informative only */ }
  return { models, structureHash };
}

// Where a global Pi install keeps the pi-ai catalog. Only fixed, non-secret locations are probed.
export function discoverCatalogDirs(env = process.env) {
  const roots = [];
  if (env.APPDATA) roots.push(path.join(env.APPDATA, 'npm', 'node_modules'));
  roots.push(path.join(path.dirname(path.dirname(process.execPath)), 'lib', 'node_modules'));
  roots.push(path.join(path.dirname(process.execPath), 'node_modules'));
  if (env.HOME) roots.push(path.join(env.HOME, '.npm-global', 'lib', 'node_modules'));
  const tail = path.join('@earendil-works', 'pi-ai', 'dist', 'providers', 'data');
  const dirs = [];
  for (const root of roots) {
    dirs.push(path.join(root, '@earendil-works', 'pi-coding-agent', 'node_modules', tail));
    dirs.push(path.join(root, tail));
  }
  return dirs;
}

function parseArgs(argv) {
  const args = { observe: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--observe') args.observe = true;
    else if (a === '--model') args.model = argv[++i];
    else if (a === '--level') args.level = argv[++i];
    else if (a === '--catalog-dir') args.catalogDir = argv[++i];
    else throw new Error(`unknown argument: ${a}`);
  }
  return args;
}

function unverified(reason) {
  console.log(`UNVERIFIED: ${reason}`);
  return 2;
}

export function main(argv, env = process.env) {
  let args;
  try { args = parseArgs(argv); } catch (e) { console.log(`USAGE: ${e.message}`); return 2; }

  if (args.observe) {
    // Fixed allow-list. Nothing else from the environment is read or printed.
    const names = ['PI_PROVIDER', 'PI_MODEL', 'PI_REASONING_LEVEL'];
    const values = names.map((n) => [n, env[n]]);
    const missing = values.filter(([, v]) => !v).map(([n]) => n);
    if (missing.length > 0) {
      return unverified(`not inside a Pi session shell, ${missing.join(', ')} not set. Do not copy the saved value into the effective field.`);
    }
    for (const [n, v] of values) console.log(`${n}=${v}`);
    return 0;
  }

  const slash = (args.model ?? '').indexOf('/');
  if (slash <= 0 || !args.level) {
    console.log('USAGE: node scripts/Get-PiEffectiveEffort.mjs --observe | --model <provider/id> --level <level> [--catalog-dir <dir>]');
    return 2;
  }
  const provider = args.model.slice(0, slash);
  const id = args.model.slice(slash + 1);

  const explicit = args.catalogDir ?? env.PI_AI_CATALOG_DIR;
  const candidates = explicit ? [explicit] : discoverCatalogDirs(env);
  const dir = candidates.find((d) => {
    try { return fs.statSync(d).isDirectory(); } catch { return false; }
  });
  if (!dir) {
    return unverified(explicit
      ? `catalog directory not found: ${explicit}`
      : 'no pi-ai catalog found on this host (pass --catalog-dir or set PI_AI_CATALOG_DIR)');
  }

  let catalog;
  try { catalog = loadCatalogDir(dir); } catch (e) {
    if (e instanceof CatalogError) return unverified(e.message);
    throw e;
  }
  const model = findModel(catalog.models, provider, id);
  if (!model) return unverified(`model ${provider}/${id} is not in the catalog at ${dir}`);

  const r = resolveEffort(model, args.level);
  console.log(`model=${provider}/${id} requested=${r.requested} effective=${r.effective} relation=${r.relation} supported=${r.supported.join(',')}`);
  console.log(`catalog=${dir} structureHash=${catalog.structureHash ?? 'unknown'} node=${process.version}`);
  if (r.match) {
    console.log('MATCH: the requested level is the level that will run.');
    return 0;
  }
  const direction = r.relation === 'up'
    ? 'a HIGHER level, so cost and time can exceed the request'
    : r.relation === 'down' ? 'a lower level' : 'a different level';
  console.log(`MISMATCH: the harness will run ${direction}. Record effective=${r.effective}, not requested=${r.requested}.`);
  return 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2));
}
