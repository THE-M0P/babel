import { test } from 'node:test';
import assert from 'node:assert/strict';
import { projectTranscript } from '../src/transcript.mjs';

test('projects user, assistant, and toolResult entries', () => {
  const entries = [
    { type: 'message', id: '1', parentId: null, timestamp: '2026-11-04T12:00:00Z',
      message: { role: 'user', content: 'fix the bug', timestamp: 1 } },
    { type: 'message', id: '2', parentId: '1', timestamp: '2026-11-04T12:00:01Z',
      message: { role: 'assistant', content: [
        { type: 'thinking', thinking: 'let me see' },
        { type: 'text', text: 'Looking at it.' },
        { type: 'toolCall', id: 'c1', name: 'read', arguments: { path: 'a.py' } },
      ], timestamp: 2 } },
    { type: 'message', id: '3', parentId: '2', timestamp: '2026-11-04T12:00:02Z',
      message: { role: 'toolResult', toolCallId: 'c1', toolName: 'read',
        content: [{ type: 'text', text: 'def bug(): pass' }], isError: false, timestamp: 3 } },
  ];
  const out = projectTranscript(entries);
  assert.deepEqual(out, [
    { role: 'user', text: 'fix the bug', ts: '2026-11-04T12:00:00Z' },
    { role: 'assistant', text: 'Looking at it.', thinking: 'let me see', ts: '2026-11-04T12:00:01Z',
      tools: [{ id: 'c1', name: 'read', args: { path: 'a.py' } }] },
    { role: 'tool_result', tool_call_id: 'c1', tool: 'read',
      result: 'def bug(): pass', truncated: false, is_error: false, ts: '2026-11-04T12:00:02Z' },
  ]);
});

test('skips system messages and non-message entries', () => {
  const entries = [
    { type: 'message', id: '1', parentId: null, timestamp: 't',
      message: { role: 'system', content: '', sections: { preamble: 'You are...' } } },
    { type: 'modelChange', id: '2', parentId: '1', timestamp: 't', model: { id: 'x' } },
    { type: 'message', id: '3', parentId: '2', timestamp: 't',
      message: { role: 'user', content: 'hi' } },
  ];
  const out = projectTranscript(entries);
  assert.deepEqual(out, [{ role: 'user', text: 'hi', ts: 't' }]);
});

test('truncates long tool results', () => {
  const entries = [
    { type: 'message', id: '1', parentId: null, timestamp: 't',
      message: { role: 'toolResult', toolCallId: 'c1', toolName: 'bash',
        content: [{ type: 'text', text: 'y'.repeat(9000) }], isError: true } },
  ];
  const out = projectTranscript(entries, 4000);
  assert.equal(out[0].result.length, 4000);
  assert.equal(out[0].truncated, true);
  assert.equal(out[0].is_error, true);
});

test('assistant with no content blocks projects empty text', () => {
  const out = projectTranscript([
    { type: 'message', id: '1', parentId: null, timestamp: 't',
      message: { role: 'assistant', content: [], timestamp: 1 } },
  ]);
  assert.deepEqual(out, [{ role: 'assistant', text: '', ts: 't' }]);
});

test('empty entry list projects empty', () => {
  assert.deepEqual(projectTranscript([]), []);
});
