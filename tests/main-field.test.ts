/**
 * Mnestra — package.json `main` and `types` field-resolution test.
 *
 * Sprint 42 T3 (TermDeck side, fixing Mnestra). Background: since v0.2.0,
 * `package.json` declared `"main": "./dist/index.js"` and
 * `"types": "./dist/index.d.ts"`, but the actual compiled artefacts live
 * at `./dist/src/index.js` / `./dist/src/index.d.ts`. tsconfig's
 * `rootDir: "."` plus `include: ["src/**\/*.ts", "mcp-server/**\/*.ts"]`
 * preserves the source-tree layout under `dist/`. The npm `bin`
 * (`./dist/mcp-server/index.js`) resolves correctly so the runtime path
 * was unaffected — but anyone consuming Mnestra as a library
 * (`require('@jhizzard/mnestra')` / `import` from the package root)
 * would hit MODULE_NOT_FOUND. This test pins the contract so a future
 * tsconfig change that re-flattens the layout has to re-update the
 * fields too.
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
// tests/ → repo root
const REPO_ROOT = path.resolve(HERE, '..', '..');

interface PackageJson {
  main?: string;
  types?: string;
  bin?: Record<string, string> | string;
}

function readPkg(): PackageJson {
  const raw = fs.readFileSync(path.join(REPO_ROOT, 'package.json'), 'utf8');
  return JSON.parse(raw);
}

test('package.json `main` points to a file that exists on disk', () => {
  const pkg = readPkg();
  assert.ok(typeof pkg.main === 'string' && pkg.main.length > 0, 'main field present');
  const resolved = path.resolve(REPO_ROOT, pkg.main!);
  assert.ok(
    fs.existsSync(resolved),
    `main field "${pkg.main}" resolves to ${resolved} which does not exist — ` +
      'tsconfig rootDir preserves source layout, so it must point under dist/src/.'
  );
});

test('package.json `types` points to a file that exists on disk', () => {
  const pkg = readPkg();
  assert.ok(typeof pkg.types === 'string' && pkg.types.length > 0, 'types field present');
  const resolved = path.resolve(REPO_ROOT, pkg.types!);
  assert.ok(
    fs.existsSync(resolved),
    `types field "${pkg.types}" resolves to ${resolved} which does not exist.`
  );
});

test('package.json `bin.mnestra` points to a file that exists on disk', () => {
  const pkg = readPkg();
  const bin = pkg.bin;
  assert.ok(bin && typeof bin === 'object', 'bin is an object map');
  const target = (bin as Record<string, string>).mnestra;
  assert.ok(typeof target === 'string' && target.length > 0, 'bin.mnestra present');
  const resolved = path.resolve(REPO_ROOT, target);
  assert.ok(
    fs.existsSync(resolved),
    `bin.mnestra "${target}" resolves to ${resolved} which does not exist.`
  );
});
