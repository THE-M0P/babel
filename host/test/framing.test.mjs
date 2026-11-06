import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JsonlFramer } from '../src/framing.mjs';

test('splits complete records on LF', () => {
  const f = new JsonlFramer();
  const out = f.push(Buffer.from('{"a":1}\n{"b":2}\n'));
  assert.deepEqual(out, [{ a: 1 }, { b: 2 }]);
});

test('buffers partial records across chunks', () => {
  const f = new JsonlFramer();
  assert.deepEqual(f.push(Buffer.from('{"a":')), []);
  assert.deepEqual(f.push(Buffer.from('1}\n')), [{ a: 1 }]);
});

test('U+2028 and U+2029 inside strings do not split records', () => {
  const f = new JsonlFramer();
  // U+2028 = \u2028, U+2029 = \u2029 — valid inside JSON strings, must survive
  const rec = { text: 'line1\u2028line2\u2029line3' };
  const out = f.push(Buffer.from(JSON.stringify(rec) + '\n'));
  assert.deepEqual(out, [rec]);
});

test('accepts CRLF line endings', () => {
  const f = new JsonlFramer();
  const out = f.push(Buffer.from('{"a":1}\r\n'));
  assert.deepEqual(out, [{ a: 1 }]);
});

test('malformed record yields a parse-error marker, not a throw', () => {
  const f = new JsonlFramer();
  const out = f.push(Buffer.from('not json\n{"ok":true}\n'));
  assert.equal(out.length, 2);
  assert.ok(out[0].__parse_error);
  assert.deepEqual(out[1], { ok: true });
});

test('empty lines are skipped', () => {
  const f = new JsonlFramer();
  const out = f.push(Buffer.from('\n\n{"a":1}\n\n'));
  assert.deepEqual(out, [{ a: 1 }]);
});
