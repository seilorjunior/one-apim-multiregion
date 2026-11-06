import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { renderDiagrams } from '../scripts/render-diagrams.mjs';

const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="160" height="40">'
  + '<text x="5" y="25" font-family="Noto Sans">APIM lab</text></svg>';

test('renders deterministically and check mode never overwrites stale exports', t => {
  const directory = mkdtempSync(join(tmpdir(), 'apim-diagrams-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const destination = join(directory, 'example.png');
  writeFileSync(join(directory, 'example.svg'), svg);
  assert.throws(() => renderDiagrams(directory, true), /Missing or stale PNG/);
  assert.equal(renderDiagrams(directory), 1);
  const first = readFileSync(destination);
  assert.equal(first.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  assert.equal(renderDiagrams(directory, true), 1);
  renderDiagrams(directory);
  assert.deepEqual(readFileSync(destination), first);
  writeFileSync(destination, 'stale');
  assert.throws(() => renderDiagrams(directory, true), /example.svg/);
  assert.equal(readFileSync(destination, 'utf8'), 'stale');
});

test('rejects empty directories and malformed SVGs', t => {
  const directory = mkdtempSync(join(tmpdir(), 'apim-diagrams-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  assert.throws(() => renderDiagrams(directory), /No SVG diagrams/);
  writeFileSync(join(directory, 'invalid.svg'), 'not an SVG');
  assert.throws(() => renderDiagrams(directory));
});

test('CLI rejects unknown flags', () => {
  const result = spawnSync(process.execPath, [
    fileURLToPath(new URL('../scripts/render-diagrams.mjs', import.meta.url)),
    '--unknown'
  ], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Usage:/);
});
