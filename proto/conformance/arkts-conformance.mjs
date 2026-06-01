#!/usr/bin/env node
// ArkTS (HarmonyOS) protocol conformance check.
//
// Validates harmony/'s FrameCodec.ets + InputCodec.ets against the golden vectors
// (proto/vectors.json) — the SAME contract the Swift (mac/Tests) and C++ (shared/cpp/tests)
// suites assert. This is the previously-missing third validator: it runs the REAL .ets codecs
// headlessly (no device), so cross-language wire drift is caught in CI.
//
// The .ets codecs are pure TypeScript, so we copy them to .ts and import them under Node's
// TypeScript support. Requires Node >= 22.7 (`--experimental-transform-types`, for the enums).
// Run via tools/check-protocol.sh, or directly:
//   node --experimental-transform-types --no-warnings proto/conformance/arkts-conformance.mjs
import { readFileSync, copyFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');                 // proto/conformance -> repo root
const vectorsPath = process.argv[2] || join(root, 'proto', 'vectors.json');  // override for testing
const etsDir = join(root, 'harmony', 'entry', 'src', 'main', 'ets', 'protocol');

// Copy the .ets codecs to a temp dir as .ts so Node loads them (it keys on the .ts extension).
const tmp = mkdtempSync(join(tmpdir(), 'sc-arkts-'));
copyFileSync(join(etsDir, 'FrameCodec.ets'), join(tmp, 'FrameCodec.ts'));
copyFileSync(join(etsDir, 'InputCodec.ets'), join(tmp, 'InputCodec.ts'));
const fc = await import(join(tmp, 'FrameCodec.ts'));
const ic = await import(join(tmp, 'InputCodec.ts'));

const hexToBytes = (h) => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const bytesToHex = (u8) => Array.from(u8, (b) => b.toString(16).padStart(2, '0')).join('');

const vf = JSON.parse(readFileSync(vectorsPath, 'utf8'));
let pass = 0, fail = 0;
const check = (ok, msg) => { if (ok) { pass++; } else { fail++; console.error('  ✗ ' + msg); } };

// --- Frame vectors: encode to exactly frameHex, and decode frameHex back to the triple. ---
for (const v of vf.vectors) {
  const enc = bytesToHex(fc.encodeFrame(v.channel, v.flags, hexToBytes(v.payloadHex)));
  check(enc === v.frameHex, `frame encode ${v.name}: got ${enc}, want ${v.frameHex}`);
  const frames = new fc.FrameDecoder().push(hexToBytes(v.frameHex));
  const f = frames[0];
  check(frames.length === 1 && f && f.channel === v.channel && f.flags === v.flags &&
        bytesToHex(f.payload) === v.payloadHex, `frame decode ${v.name}`);
}

// --- Input vectors: fixed 44-byte record encodes to exactly recordHex. ---
check(ic.INPUT_RECORD_SIZE === vf.inputRecordSize,
      `INPUT_RECORD_SIZE ${ic.INPUT_RECORD_SIZE} != ${vf.inputRecordSize}`);
for (const v of vf.inputVectors) {
  const enc = bytesToHex(ic.encodeInput(v));
  check(enc === v.recordHex, `input encode ${v.name}: got ${enc}, want ${v.recordHex}`);
}

console.log(`ArkTS conformance: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
