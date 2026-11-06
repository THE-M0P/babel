// fake-pi.mjs — minimal `deepthought --mode rpc` stand-in for server tests.
//
// Speaks just enough of the RPC protocol: responds to get_state /
// get_entries / prompt / steer / abort, and emits an agent_start +
// agent_settled pair for each prompt (so the full frame pipeline runs).
//
// Env:
//   FAKE_PI_DIE=1   exit immediately after spawn (dead-session tests)
//   FAKE_PI_DELAY_MS=N   sleep N ms before answering (startup tests)
//   FAKE_PI_RUN_MS=N   sleep N ms between agent_start and agent_settled
//                      (gives tests a window to observe an in-flight run)
//   FAKE_PI_NAME=TEXT  emit a session_info_changed event after the first
//                      prompt settles (simulates pi's auto-naming)

import { setTimeout as delay } from 'node:timers/promises';
import { appendFileSync } from 'node:fs';

if (process.env.FAKE_PI_DIE === '1') process.exit(3);
if (process.env.FAKE_PI_DELAY_MS) await delay(Number(process.env.FAKE_PI_DELAY_MS));

const out = (obj) => process.stdout.write(JSON.stringify(obj) + '\n');

let buf = '';
process.stdin.on('data', (c) => {
  buf += c.toString('utf8');
  let i;
  while ((i = buf.indexOf('\n')) !== -1) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let req;
    try { req = JSON.parse(line); } catch { continue; }
    if (process.env.FAKE_PI_LOG) appendFileSync(process.env.FAKE_PI_LOG, req.type + '\n');
    switch (req.type) {
      case 'get_state':
        out({ type: 'response', command: 'get_state', success: true, id: req.id,
          data: { model: { id: 'fake/model' }, isStreaming: false, sessionFile: '/tmp/fake-pi-session.jsonl' } });
        break;
      case 'get_entries':
        out({ type: 'response', command: 'get_entries', success: true, id: req.id,
          data: { entries: [
            { type: 'session', id: 'fake', cwd: '/tmp' },
            { type: 'message', id: 'm1', parentId: null, timestamp: 't',
              message: { role: 'user', content: 'hello fake', timestamp: 1 } },
          ] } });
        break;
      case 'prompt':
        out({ type: 'response', command: 'prompt', success: true, id: req.id,
          data: { disposition: 'started' } });
        out({ type: 'agent_start' });
        out({ type: 'message_update', assistantMessageEvent: { type: 'text_delta', delta: 'fake reply' } });
        if (process.env.FAKE_PI_RUN_MS) {
          delay(Number(process.env.FAKE_PI_RUN_MS)).then(() => {
            out({ type: 'agent_settled', aborted: false });
            if (process.env.FAKE_PI_NAME) {
              out({ type: 'session_info_changed', name: process.env.FAKE_PI_NAME });
            }
          });
        } else {
          out({ type: 'agent_settled', aborted: false });
          if (process.env.FAKE_PI_NAME) {
            out({ type: 'session_info_changed', name: process.env.FAKE_PI_NAME });
          }
        }
        break;
      case 'steer':
        out({ type: 'response', command: 'steer', success: true, id: req.id, data: {} });
        break;
      case 'abort':
        out({ type: 'response', command: 'abort', success: true, id: req.id, data: {} });
        out({ type: 'agent_settled', aborted: true });
        break;
      default:
        out({ type: 'response', command: req.type, success: true, id: req.id, data: {} });
    }
  }
});
