// Integration test: real `deepthought --mode rpc` child + WS client driving
// the contract end to end. Runs against the real LLM when reachable;
// the failure path (LLM down) is also acceptable — we assert the contract
// machinery, not the model.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, rmSync } from 'node:fs';

// These tests drive a REAL pi child (any binary with --mode rpc: upstream
// pi, or a fork). Default: `pi` on PATH; override with BABEL_TEST_PI_BIN.
// Skipped when the binary is not installed.
const PI_BIN = process.env.BABEL_TEST_PI_BIN ?? 'pi';
const hasPi = spawnSync(PI_BIN, ['--version'], { stdio: 'ignore' }).status === 0;
const piSkip = hasPi ? false : `no pi binary found (set BABEL_TEST_PI_BIN; got: ${PI_BIN})`;
import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';
import { WebSocket } from 'ws';
import { BabelServer } from '../src/server.mjs';

const logs = [];
const log = (m) => { logs.push(m); console.log(m); };

class TestClient {
  constructor(url) {
    this.url = url;
    this.frames = [];
    this.waiters = [];
  }

  connect() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(this.url);
      this.ws.on('open', () => resolve());
      this.ws.on('error', reject);
      this.ws.on('message', (data) => {
        const frame = JSON.parse(data.toString('utf8'));
        this.frames.push(frame);
        for (const w of [...this.waiters]) {
          if (w.pred(frame)) {
            this.waiters.splice(this.waiters.indexOf(w), 1);
            w.resolve(frame);
          }
        }
      });
      // keep the host from idle-closing us during long LLM runs
      this._ping = setInterval(() => {
        if (this.ws?.readyState === WebSocket.OPEN) {
          this.ws.send(JSON.stringify({ v: 1, type: 'ping' }));
        }
      }, 20_000);
    });
  }

  close() {
    clearInterval(this._ping);
    this.ws?.close();
  }

  send(obj) {
    this.ws.send(JSON.stringify(obj));
  }

  /** Wait for a frame matching pred (scans history first). */
  waitFor(pred, timeoutMs = 30_000, what = 'frame') {
    const hit = this.frames.find(pred);
    if (hit) return Promise.resolve(hit);
    return new Promise((resolve, reject) => {
      const w = { pred, resolve };
      this.waiters.push(w);
      setTimeout(() => {
        const i = this.waiters.indexOf(w);
        if (i !== -1) {
          this.waiters.splice(i, 1);
          reject(new Error(`timeout waiting for ${what}\nframes: ${JSON.stringify(this.frames.map((f) => f.type))}\nlogs: ${logs.slice(-15).join(' | ')}`));
        }
      }, timeoutMs);
    });
  }

  request(obj) {
    this.send({ v: 1, ...obj });
    return this.waitFor((f) => f.id === obj.id && f.type === `${obj.type}_response`, 30_000, `${obj.type}_response`);
  }
}

test('contract end-to-end against a real pi child', { timeout: 180_000, skip: piSkip }, async (t) => {
  const root = mkdirSync(join(tmpdir(), `babel-it-${Date.now()}`), { recursive: true });
  const cwd = mkdirSync(join(root, 'work'), { recursive: true });
  const sessionDir = join(root, 'sessions');
  const token = 'test-token';

  const server = new BabelServer({
    port: 0,
    bind: '127.0.0.1',
    token,
    piBin: PI_BIN,
    sessionDir,
    maxSessions: 2,
    toolResultMax: 4000,
    hostVersion: '0.1.0-test',
    log,
  });
  await server.start();
  const port = server.wss.address().port;
  t.after(() => { server.stop().catch(() => {}); rmSync(root, { recursive: true, force: true }); });

  const client = new TestClient(`ws://127.0.0.1:${port}/ws?token=${token}`);
  await client.connect();
  t.after(() => client.close());

  // 1. hello + session_list on connect
  const hello = await client.waitFor((f) => f.type === 'hello', 5000, 'hello');
  assert.equal(hello.server, 'babel-host');
  assert.equal(hello.contract, 1);
  await client.waitFor((f) => f.type === 'session_list', 5000, 'session_list');

  // 2. bad token is rejected (4401)
  await new Promise((resolve) => {
    const bad = new WebSocket(`ws://127.0.0.1:${port}/ws?token=wrong`);
    bad.on('close', (code) => { assert.equal(code, 4401); resolve(); });
    bad.on('error', () => resolve());
  });

  // 3. new_session
  const ns = await client.request({ id: 'r1', type: 'new_session', cwd: String(cwd), name: 'it-test' });
  assert.equal(ns.ok, true, JSON.stringify(ns));
  const sid = ns.session_id;
  assert.ok(sid);

  // 4. attach → empty transcript
  const at = await client.request({ id: 'r2', type: 'attach', session_id: sid });
  assert.equal(at.ok, true, JSON.stringify(at));
  const t0 = await client.waitFor((f) => f.type === 'transcript' && f.session_id === sid, 15_000, 'transcript');
  assert.deepEqual(t0.entries, []);

  // 5. prompt → run machinery
  const pr = await client.request({ id: 'r3', type: 'prompt', session_id: sid, text: 'Reply with exactly: ok' });
  assert.equal(pr.ok, true, JSON.stringify(pr));
  await client.waitFor((f) => f.type === 'run_started' && f.session_id === sid, 30_000, 'run_started');

  // 6. run finishes (real LLM: quick reply; LLM down: retries then settles)
  const fin = await client.waitFor(
    (f) => f.type === 'run_finished' && f.session_id === sid,
    120_000, 'run_finished',
  );
  assert.equal(typeof fin.aborted, 'boolean');

  // 7. transcript now contains the user turn
  const rs = await client.request({ id: 'r4', type: 'resnapshot', session_id: sid });
  assert.equal(rs.ok, true);
  const t1 = await client.waitFor(
    (f) => f.type === 'transcript' && f.session_id === sid && f.entries.length > 0,
    15_000, 'non-empty transcript',
  );
  assert.equal(t1.entries[0].role, 'user');
  assert.equal(t1.entries[0].text, 'Reply with exactly: ok');

  // 8. abort is a no-op when idle but must succeed
  const ab = await client.request({ id: 'r5', type: 'abort', session_id: sid });
  assert.equal(ab.ok, true, JSON.stringify(ab));

  // 9. session_list reflects the session (and the starting→idle transition)
  const ls = await client.request({ id: 'r6', type: 'list_sessions' });
  assert.equal(ls.ok, true);
  const list = await client.waitFor(
    (f) => f.type === 'session_list' && f.sessions.some((s) => s.id === sid && s.status === 'idle'),
    5000, 'idle session_list',
  );
  const entry = list.sessions.find((s) => s.id === sid);
  assert.ok(entry);
  assert.equal(entry.name, 'it-test');
  assert.equal(entry.status, 'idle');

  // 10. unknown session is reported
  const bad = await client.request({ id: 'r7', type: 'attach', session_id: 's_nope' });
  assert.equal(bad.ok, false);
  assert.match(bad.error, /unknown session/);
});

test('steer mid-run and abort', { timeout: 240_000, skip: piSkip }, async (t) => {
  const root = mkdirSync(join(tmpdir(), `babel-it2-${Date.now()}`), { recursive: true });
  const cwd = mkdirSync(join(root, 'work'), { recursive: true });
  const server = new BabelServer({
    port: 0, bind: '127.0.0.1', token: 't2',
    piBin: PI_BIN, sessionDir: join(root, 'sessions'),
    maxSessions: 2, toolResultMax: 4000, hostVersion: 'test', log,
  });
  await server.start();
  t.after(() => { server.stop().catch(() => {}); rmSync(root, { recursive: true, force: true }); });

  const client = new TestClient(`ws://127.0.0.1:${server.wss.address().port}/ws?token=t2`);
  await client.connect();
  t.after(() => client.close());

  const ns = await client.request({ id: 'a1', type: 'new_session', cwd: String(cwd) });
  assert.equal(ns.ok, true, JSON.stringify(ns));
  const sid = ns.session_id;
  const at = await client.request({ id: 'a0', type: 'attach', session_id: sid });
  assert.equal(at.ok, true, JSON.stringify(at));

  // 1. a long-ish run, then steer into it
  const pr = await client.request({ id: 'a2', type: 'prompt', session_id: sid, text: 'Count slowly from 1 to 25, one number per line. Do not stop early.' });
  assert.equal(pr.ok, true, JSON.stringify(pr));
  await client.waitFor((f) => f.type === 'run_started' && f.session_id === sid, 30_000, 'run_started');

  // give the run a moment to be mid-stream, then steer
  await new Promise((r) => setTimeout(r, 8000));
  const st = await client.request({ id: 'a3', type: 'steer', session_id: sid, text: 'Stop counting. Just reply with the single word: done.' });
  assert.equal(st.ok, true, JSON.stringify(st));

  const fin = await client.waitFor((f) => f.type === 'run_finished' && f.session_id === sid, 120_000, 'run_finished');
  assert.equal(typeof fin.aborted, 'boolean');

  // 2. abort while idle is a clean no-op
  const ab = await client.request({ id: 'a4', type: 'abort', session_id: sid });
  assert.equal(ab.ok, true, JSON.stringify(ab));
});

test('stored session survives a host restart and resumes', { timeout: 240_000, skip: piSkip }, async (t) => {
  // root must NOT be under /tmp — the host hides /tmp scratch sessions
  // from the stored list, which would hide this test's own session.
  const root = mkdirSync(join(homedir(), `.babel-it-${Date.now()}`), { recursive: true });
  const cwd = mkdirSync(join(root, 'work'), { recursive: true });
  const sessionDir = join(root, 'sessions');

  const mkServer = () => new BabelServer({
    port: 0, bind: '127.0.0.1', token: 't3',
    piBin: PI_BIN, sessionDir,
    maxSessions: 2, toolResultMax: 4000, hostVersion: 'test', log,
  });

  // --- first life: create a session, run a prompt, let it settle ---
  let server = mkServer();
  await server.start();
  let client = new TestClient(`ws://127.0.0.1:${server.wss.address().port}/ws?token=t3`);
  await client.connect();

  const ns = await client.request({ id: 'b1', type: 'new_session', cwd: String(cwd) });
  assert.equal(ns.ok, true, JSON.stringify(ns));
  const sid = ns.session_id;
  const at = await client.request({ id: 'b0', type: 'attach', session_id: sid });
  assert.equal(at.ok, true, JSON.stringify(at));

  const pr = await client.request({ id: 'b2', type: 'prompt', session_id: sid, text: 'Reply with exactly: ok' });
  assert.equal(pr.ok, true, JSON.stringify(pr));
  await client.waitFor((f) => f.type === 'run_finished' && f.session_id === sid, 120_000, 'run_finished');

  client.close();
  await server.stop(); // kills the pi child — session file remains on disk

  // --- second life: new host, session must appear as stored and resume ---
  server = mkServer();
  await server.start();
  t.after(() => { server.stop().catch(() => {}); rmSync(root, { recursive: true, force: true }); });

  client = new TestClient(`ws://127.0.0.1:${server.wss.address().port}/ws?token=t3`);
  await client.connect();
  t.after(() => client.close());

  const list = await client.waitFor(
    (f) => f.type === 'session_list' && f.sessions.some((s) => s.id === sid && s.status === 'stored'),
    15_000, 'stored session in list',
  );
  const entry = list.sessions.find((s) => s.id === sid);
  assert.equal(entry.status, 'stored');

  // attach resumes it: transcript must contain the earlier turn
  const at2 = await client.request({ id: 'b3', type: 'attach', session_id: sid });
  assert.equal(at2.ok, true, JSON.stringify(at2));
  const tr = await client.waitFor(
    (f) => f.type === 'transcript' && f.session_id === sid && f.entries.length > 0,
    30_000, 'resumed transcript',
  );
  assert.equal(tr.entries[0].role, 'user');
  assert.match(tr.entries[0].text, /Reply with exactly: ok/);

  // and it is promptable again
  const pr2 = await client.request({ id: 'b4', type: 'prompt', session_id: sid, text: 'Reply with exactly: ok2' });
  assert.equal(pr2.ok, true, JSON.stringify(pr2));
  await client.waitFor((f) => f.type === 'run_finished' && f.session_id === sid, 120_000, 'second run_finished');
});
