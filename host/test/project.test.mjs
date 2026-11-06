import { test } from 'node:test';
import assert from 'node:assert/strict';
import { projectEvent, textOf, truncate } from '../src/project.mjs';

function ctx(overrides = {}) {
  return { session_id: 's_test', runId: null, nextRunId: 1, nextSeq: 1, toolResultMax: 4000, ...overrides };
}

test('agent_start emits run_started + status running, mints a run id', () => {
  const c = ctx();
  const frames = projectEvent({ type: 'agent_start' }, c);
  assert.deepEqual(frames, [
    { session_id: 's_test', seq: 1, type: 'run_started', run_id: 'run_1' },
    { session_id: 's_test', seq: 2, type: 'status', state: 'running' },
  ]);
  assert.equal(c.runId, 'run_1');
});

test('text_delta projects with run id and advancing seq', () => {
  const c = ctx({ runId: 'run_1' });
  const frames = projectEvent(
    { type: 'message_update', assistantMessageEvent: { type: 'text_delta', delta: 'Hello ' } },
    c,
  );
  assert.deepEqual(frames, [
    { session_id: 's_test', seq: 1, type: 'text_delta', run_id: 'run_1', delta: 'Hello ' },
  ]);
});

test('thinking_delta projects', () => {
  const c = ctx({ runId: 'run_1' });
  const frames = projectEvent(
    { type: 'message_update', assistantMessageEvent: { type: 'thinking_delta', delta: 'hmm' } },
    c,
  );
  assert.equal(frames[0].type, 'thinking_delta');
  assert.equal(frames[0].delta, 'hmm');
});

test('toolcall block events are absorbed (tool_execution_* carries those)', () => {
  const c = ctx({ runId: 'run_1' });
  const frames = projectEvent(
    { type: 'message_update', assistantMessageEvent: { type: 'toolcall_start', partial: {} } },
    c,
  );
  assert.deepEqual(frames, []);
});

test('tool_execution lifecycle projects start/update/end', () => {
  const c = ctx({ runId: 'run_1' });
  const start = projectEvent(
    { type: 'tool_execution_start', toolCallId: 'c1', toolName: 'bash', args: { command: 'ls' } },
    c,
  );
  assert.deepEqual(start[0], {
    session_id: 's_test', seq: 1, type: 'tool_start', run_id: 'run_1',
    tool_call_id: 'c1', name: 'bash', args: { command: 'ls' },
  });

  const update = projectEvent(
    { type: 'tool_execution_update', toolCallId: 'c1', toolName: 'bash', args: {},
      partialResult: { content: [{ type: 'text', text: 'partial out' }] } },
    c,
  );
  assert.equal(update[0].type, 'tool_update');
  assert.equal(update[0].partial, 'partial out');

  const end = projectEvent(
    { type: 'tool_execution_end', toolCallId: 'c1', toolName: 'bash',
      result: { content: [{ type: 'text', text: 'final out' }] }, isError: false },
    c,
  );
  assert.deepEqual(end[0], {
    session_id: 's_test', seq: 3, type: 'tool_end', run_id: 'run_1',
    tool_call_id: 'c1', is_error: false, result: 'final out', truncated: false,
  });
});

test('tool_end truncates long results and flags it', () => {
  const c = ctx({ runId: 'run_1', toolResultMax: 10 });
  const frames = projectEvent(
    { type: 'tool_execution_end', toolCallId: 'c1', toolName: 'read',
      result: { content: [{ type: 'text', text: 'x'.repeat(50) }] }, isError: false },
    c,
  );
  assert.equal(frames[0].result.length, 10);
  assert.equal(frames[0].truncated, true);
});

test('agent_settled emits run_finished + status idle', () => {
  const c = ctx({ runId: 'run_1' });
  const frames = projectEvent({ type: 'agent_settled', aborted: false }, c);
  assert.deepEqual(frames, [
    { session_id: 's_test', seq: 1, type: 'run_finished', run_id: 'run_1', aborted: false },
    { session_id: 's_test', seq: 2, type: 'status', state: 'idle' },
  ]);
});

test('compaction and retry events project', () => {
  const c = ctx({ runId: 'run_1' });
  assert.equal(projectEvent({ type: 'compaction_start', reason: 'threshold' }, c)[0].type, 'compaction');
  assert.equal(projectEvent({ type: 'compaction_end' }, c)[0].state, 'finished');
  const retry = projectEvent(
    { type: 'auto_retry_start', attempt: 1, maxAttempts: 3, delayMs: 2000, errorMessage: '529 overloaded' },
    c,
  );
  assert.deepEqual(retry[0], {
    session_id: 's_test', seq: 3, type: 'retry',
    attempt: 1, max_attempts: 3, message: '529 overloaded',
  });
});

test('session_info_changed projects a session_renamed frame', () => {
  const c = ctx();
  const frames = projectEvent({ type: 'session_info_changed', name: 'My Title' }, c);
  assert.deepEqual(frames, [{ session_id: 's_test', seq: 1, type: 'session_renamed', name: 'My Title' }]);
  // empty name (cleared) is absorbed
  assert.deepEqual(projectEvent({ type: 'session_info_changed', name: undefined }, c), []);
});

test('extension_ui_request confirm projects a needs_input frame', () => {
  const c = ctx();
  const frames = projectEvent({
    type: 'extension_ui_request', id: 'req1', method: 'confirm',
    title: 'Run bash?', message: 'npm test', timeout: 30000,
  }, c);
  assert.deepEqual(frames, [{
    session_id: 's_test', seq: 1, type: 'needs_input',
    request_id: 'req1', kind: 'confirm', title: 'Run bash?',
    message: 'npm test', timeout_ms: 30000,
  }]);
});

test('extension_ui_request select carries options', () => {
  const c = ctx();
  const frames = projectEvent({
    type: 'extension_ui_request', id: 'req2', method: 'select',
    title: 'Pick a target', options: ['a', 'b'],
  }, c);
  assert.equal(frames[0].kind, 'select');
  assert.deepEqual(frames[0].options, ['a', 'b']);
});

test('extension_ui_request input/editor carry placeholder/prefill', () => {
  const c = ctx();
  const f1 = projectEvent({ type: 'extension_ui_request', id: 'r', method: 'input', title: 'Name?', placeholder: 'type here' }, c);
  assert.equal(f1[0].placeholder, 'type here');
  const f2 = projectEvent({ type: 'extension_ui_request', id: 'r', method: 'editor', title: 'Edit', prefill: 'old text' }, c);
  assert.equal(f2[0].prefill, 'old text');
});

test('extension_ui_request notify projects a notice frame', () => {
  const c = ctx();
  const frames = projectEvent({
    type: 'extension_ui_request', id: 'req3', method: 'notify',
    message: 'heating up', notifyType: 'warning',
  }, c);
  assert.deepEqual(frames, [{ session_id: 's_test', seq: 1, type: 'notice', level: 'warning', message: 'heating up' }]);
});

test('extension_ui_request setStatus/setWidget are absorbed', () => {
  const c = ctx();
  assert.deepEqual(projectEvent({ type: 'extension_ui_request', id: 'r', method: 'setStatus', statusKey: 'k', statusText: 'v' }, c), []);
  assert.deepEqual(projectEvent({ type: 'extension_ui_request', id: 'r', method: 'setWidget', widgetKey: 'w' }, c), []);
});

test('unknown events are absorbed', () => {
  const c = ctx();
  assert.deepEqual(projectEvent({ type: 'message_start', message: {} }, c), []);
  assert.deepEqual(projectEvent({ type: 'turn_start' }, c), []);
  assert.deepEqual(projectEvent({ type: 'something_new' }, c), []);
});

test('textOf handles strings, block arrays, and null', () => {
  assert.equal(textOf('plain'), 'plain');
  assert.equal(textOf([{ type: 'text', text: 'a' }, { type: 'thinking', thinking: 'b' }, { type: 'text', text: 'c' }]), 'ac');
  assert.equal(textOf(null), '');
});

test('truncate flags and bounds', () => {
  assert.deepEqual(truncate('short', 10), { text: 'short', truncated: false });
  assert.deepEqual(truncate('x'.repeat(15), 10), { text: 'x'.repeat(10), truncated: true });
});
