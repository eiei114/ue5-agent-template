// Regression suite for scripts/Get-PiEffectiveEffort.mjs and for the docs that point at it (DOT-3240).
// Needs only node. It builds its own fixture catalog, never calls a model, and never reads settings,
// auth files or the full environment.
//
// Run: node scripts/Test-PiEffectiveEffort.mjs
// Exit: 0 all assertions held / 1 an assertion failed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..');
const helperPath = path.join(here, 'Get-PiEffectiveEffort.mjs');

const mod = await import(new URL('./Get-PiEffectiveEffort.mjs', import.meta.url).href);

// The shape mirrors @earendil-works/pi-ai dist/providers/data/<provider>.json: { <api>: { "<type>:<id>": model } }.
const fixtureCatalog = {
  'openai-completions': {
    // supported = [low, high, max]: no medium, so medium is clamped UP to high.
    'chat:gap-model': {
      id: 'gap-model', provider: 'fixture', reasoning: true,
      thinkingLevelMap: { minimal: null, low: 'low', medium: null, high: 'high', max: 'max' },
    },
    // supported = [off, minimal, low, medium, high]: no max, so max is clamped to high.
    'chat:no-max-model': {
      id: 'no-max-model', provider: 'fixture', reasoning: true,
    },
    // every level supported: a request passes through unchanged.
    'chat:full-model': {
      id: 'full-model', provider: 'fixture', reasoning: true,
      thinkingLevelMap: { xhigh: 'xhigh', max: 'max' },
    },
    // not a reasoning model: only off exists.
    'chat:plain-model': {
      id: 'plain-model', provider: 'fixture', reasoning: false,
    },
  },
};

function writeCatalog(dir, catalog = fixtureCatalog) {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'fixture.json'), JSON.stringify(catalog));
}

function withTempDir(fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pi-effort-'));
  try { return fn(dir); } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

function runCli(args, env = {}) {
  // Start from an empty environment so a developer's own PI_* variables and catalog hints cannot change the verdict.
  const r = spawnSync(process.execPath, [helperPath, ...args], {
    encoding: 'utf8',
    env: { PATH: '', SystemRoot: process.env.SystemRoot ?? '', ...env },
  });
  return { status: r.status, out: `${r.stdout}${r.stderr}` };
}

function resolveFixture(modelId, level) {
  const model = mod.findModel(fixtureCatalog_models(), 'fixture', modelId);
  assert.ok(model, `fixture model ${modelId} must exist`);
  return mod.resolveEffort(model, level);
}

function fixtureCatalog_models() {
  return mod.flattenCatalog('fixture', fixtureCatalog);
}

test('(a) a level the model lacks is clamped UP: medium -> high', () => {
  const r = resolveFixture('gap-model', 'medium');
  assert.equal(r.effective, 'high');
  assert.equal(r.relation, 'up');
  assert.equal(r.match, false);
});

test('(a) off and minimal are also clamped UP on a model without them', () => {
  assert.equal(resolveFixture('gap-model', 'off').effective, 'low');
  assert.equal(resolveFixture('gap-model', 'minimal').effective, 'low');
});

test('(b) max on a model without max becomes high (a downward substitution)', () => {
  const r = resolveFixture('no-max-model', 'max');
  assert.equal(r.effective, 'high');
  assert.equal(r.relation, 'down');
  assert.equal(r.match, false);
});

test('(b) xhigh on a model whose supported set tops out at max is clamped UP to max', () => {
  const r = resolveFixture('gap-model', 'xhigh');
  assert.equal(r.effective, 'max');
  assert.equal(r.relation, 'up');
});

test('(c) a supported request passes through unchanged', () => {
  for (const level of ['off', 'low', 'medium', 'high', 'xhigh', 'max']) {
    const r = resolveFixture('full-model', level);
    assert.equal(r.effective, level);
    assert.equal(r.relation, 'same');
    assert.equal(r.match, true);
  }
});

test('(e) a model with reasoning:false only ever runs at off', () => {
  const r = resolveFixture('plain-model', 'max');
  assert.deepEqual(r.supported, ['off']);
  assert.equal(r.effective, 'off');
  assert.equal(r.match, false);
  assert.equal(resolveFixture('plain-model', 'off').match, true);
});

test('an unknown level name is not silently accepted', () => {
  const r = resolveFixture('full-model', 'ultra');
  assert.equal(r.match, false);
  assert.equal(r.relation, 'unknown-level');
});

test('CLI (a): medium on gap-model exits 1 and names the effective level', () => withTempDir((dir) => {
  writeCatalog(dir);
  const r = runCli(['--catalog-dir', dir, '--model', 'fixture/gap-model', '--level', 'medium']);
  assert.equal(r.status, 1, r.out);
  assert.match(r.out, /requested=medium/);
  assert.match(r.out, /effective=high/);
  assert.match(r.out, /MISMATCH/);
}));

test('CLI (b): max on no-max-model exits 1 with effective=high', () => withTempDir((dir) => {
  writeCatalog(dir);
  const r = runCli(['--catalog-dir', dir, '--model', 'fixture/no-max-model', '--level', 'max']);
  assert.equal(r.status, 1, r.out);
  assert.match(r.out, /effective=high/);
}));

test('CLI (c): a supported request exits 0 and reports a match', () => withTempDir((dir) => {
  writeCatalog(dir);
  const r = runCli(['--catalog-dir', dir, '--model', 'fixture/full-model', '--level', 'max']);
  assert.equal(r.status, 0, r.out);
  assert.match(r.out, /MATCH/);
  assert.match(r.out, /effective=max/);
}));

test('CLI (d): a missing catalog is UNVERIFIED (exit 2), never a pass', () => withTempDir((dir) => {
  const r = runCli(['--catalog-dir', path.join(dir, 'does-not-exist'), '--model', 'fixture/full-model', '--level', 'max']);
  assert.equal(r.status, 2, r.out);
  assert.match(r.out, /UNVERIFIED/);
  assert.doesNotMatch(r.out, /\bMATCH\b/);
}));

test('CLI (d): no catalog location at all is UNVERIFIED (exit 2)', () => {
  const r = runCli(['--model', 'fixture/full-model', '--level', 'max']);
  assert.equal(r.status, 2, r.out);
  assert.match(r.out, /UNVERIFIED/);
});

test('CLI (d): a model absent from the catalog is UNVERIFIED (exit 2)', () => withTempDir((dir) => {
  writeCatalog(dir);
  const r = runCli(['--catalog-dir', dir, '--model', 'fixture/nope', '--level', 'max']);
  assert.equal(r.status, 2, r.out);
  assert.match(r.out, /UNVERIFIED/);
}));

test('CLI (e): reasoning:false model with max exits 1 and reports effective=off', () => withTempDir((dir) => {
  writeCatalog(dir);
  const r = runCli(['--catalog-dir', dir, '--model', 'fixture/plain-model', '--level', 'max']);
  assert.equal(r.status, 1, r.out);
  assert.match(r.out, /effective=off/);
}));

test('CLI: a corrupt catalog is UNVERIFIED, not a crash that looks like a pass', () => withTempDir((dir) => {
  fs.writeFileSync(path.join(dir, 'fixture.json'), '{not json');
  const r = runCli(['--catalog-dir', dir, '--model', 'fixture/full-model', '--level', 'max']);
  assert.equal(r.status, 2, r.out);
  assert.match(r.out, /UNVERIFIED/);
}));

test('--observe prints only the three PI_* variables and never PI_SESSION_*', () => {
  const r = runCli(['--observe'], {
    PI_PROVIDER: 'fixture', PI_MODEL: 'gap-model', PI_REASONING_LEVEL: 'high',
    PI_SESSION_ID: 'must-not-appear', PI_SESSION_FILE: 'must-not-appear', SECRET_TOKEN: 'must-not-appear',
  });
  assert.equal(r.status, 0, r.out);
  assert.match(r.out, /PI_PROVIDER=fixture/);
  assert.match(r.out, /PI_MODEL=gap-model/);
  assert.match(r.out, /PI_REASONING_LEVEL=high/);
  assert.doesNotMatch(r.out, /must-not-appear/);
});

test('--observe outside a Pi session is UNVERIFIED (exit 2), not an empty pass', () => {
  const r = runCli(['--observe']);
  assert.equal(r.status, 2, r.out);
  assert.match(r.out, /UNVERIFIED/);
});

// The docs half of the contract. These fail on a tree that only has the helper.
const read = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');

test('docs/02-runtime.md carries the observation section, the upward clamp and the max -> high example', () => {
  const doc = read('docs/02-runtime.md');
  assert.match(doc, /^## 実効値の観測/m);
  assert.match(doc, /Get-PiEffectiveEffort\.mjs --observe/);
  assert.match(doc, /PI_REASONING_LEVEL/);
  assert.match(doc, /より高い/);
  assert.match(doc, /`max`[^\n]*`high`/);
  assert.match(doc, /実効値[^\n]*正本/);
});

test('docs/02-runtime.md keeps the historical Opus record untouched', () => {
  const doc = read('docs/02-runtime.md');
  assert.match(doc, /^## 過去案件限定の確定記録/m);
  assert.match(doc, /PI_CLAUDE_CLI_ALLOW_USAGE_CREDITS=0/);
});

test('templates/QA.md splits model/effort into 指定 / 保存 / 実効 / 一致 and defines no', () => {
  const qa = read('templates/QA.md');
  for (const label of ['指定effort：', '保存effort：', '実効effort：', '一致（yes / no / 不明）：']) {
    assert.ok(qa.includes(label), `QA.md must contain a line for ${label}`);
  }
  assert.match(qa, /一致が`no`[^\n]*実効[^\n]*正本/);
});

test('docs/01-start.md points the preflight at the observation section', () => {
  const doc = read('docs/01-start.md');
  assert.match(doc, /不明と書く前に[^\n]*実効値の観測/);
});
