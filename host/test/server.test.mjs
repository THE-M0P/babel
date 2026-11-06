// Server unit tests: auth, routing, stored-scan, lifecycle.
// Uses fake-pi.mjs as the pi binary — no real LLM involved.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync, chmodSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocket } from 'ws';
import { BabelServer } from '../src/server.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const fakePi = join(here, 'fake-pi.mjs');

function wrapper(env = {}) {
  const f = join(tmpdir(), `fake-pi-bin-${Math.random().toString(16).slice(2)}.sh`);
  const envLines = Object.entries(env).map(([k, v]) => `export ${k}="${v}"`).join('\n');
  writeFileSync(f, `#!/usr/bin/env bash\n${envLines}\nexec node ${fakePi} "$@"\n`);
  chmodSync(f, 0o755);
  return f;
}

class Client {
  constructor(url) { this.url = url; this.frames = []; }
  connect() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(this.url);
      this.ws.on('open', resolve);
      this.ws.on('error', reject);
      this.ws.on('close', (code) => { this.closeCode = code; this.onClose?.(code); });
      this.ws.on('message', (d) => {
        const f = JSON.parse(d.toString('utf8'));
        this.frames.push(f);
        this.onFrame?.(f);
      });
    });
  }
  send(o) { this.ws.send(JSON.stringify(o)); }
  waitFor(pred, ms = 5000, what = 'frame') {
    const hit = this.frames.find(pred);
    if (hit) return Promise.resolve(hit);
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`timeout waiting for ${what}`)), ms);
      const h = (f) => {
        if (pred(f)) { clearTimeout(t); this.onFrame = undefined; resolve(f); }
      };
      this.onFrame = h;
    });
  }
  close() { this.ws?.close(); }
}

let root, server, port;
const logs = [];

/** Wait until the session map drains (dead children propagate async). */
async function drainMap(expected = 0) {
  for (let i = 0; i < 100 && server.sessions.size !== expected; i++) {
    await new Promise((r) => setTimeout(r, 50));
  }
  assert.equal(server.sessions.size, expected, 'session map should have drained');
}

before(async () => {
  root = mkdirSync(join(tmpdir(), `babel-server-test-${Date.now()}`), { recursive: true });
  server = new BabelServer({
    port: 0,
    bind: '127.0.0.1',
    token: 'test-token',
    piBin: wrapper(),
    sessionDir: join(root, 'sessions'),
    maxSessions: 2,
    toolResultMax: 4000,
    hostVersion: 'test',
    log: (m) => logs.push(m),
  });
  await server.start();
  port = server.wss.address().port;
});

after(async () => {
  await server.stop();
  rmSync(root, { recursive: true, force: true });
});

test('rename_session appends session_info and updates the list', async () => {
  mkdirSync(join(root, 'sessions'), { recursive: true });
  const id = 'test-rename-0001';
  const file = join(root, 'sessions', `${id}.jsonl`);
  writeFileSync(file, [
    JSON.stringify({ type: 'session', id, version: 1, cwd: '/home/test/x', created_at: '2026-11-04T10:00:00Z' }),
    JSON.stringify({ type: 'message', id: 'm1', parentId: null, timestamp: '2026-11-04T10:00:01Z', message: { role: 'user', content: [{ type: 'text', text: 'hello' }] } }),
  ].join('\n') + '\n');

  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  c.send({ v: 1, id: 'ls1', type: 'list_sessions' });
  const list1 = await c.waitFor(
      (f) => f.type === 'session_list' && f.sessions.some((s) => s.id === id),
      5000, 'session_list containing the new file');
  const entry1 = list1.sessions.find((s) => s.id === id);
  assert.equal(entry1.name, 'hello');

  c.send({ v: 1, id: 'rn1', type: 'rename_session', session_id: id, name: 'my renamed session' });
  const ok = await c.waitFor((f) => f.type === 'rename_session_response' && f.id === 'rn1');
  assert.equal(ok.ok, true);

  // file gained a session_info entry with the new name
  const lines = (await import('node:fs')).readFileSync(file, 'utf8').trim().split('\n');
  const last = JSON.parse(lines[lines.length - 1]);
  assert.equal(last.type, 'session_info');
  assert.equal(last.name, 'my renamed session');
  assert.equal(last.parentId, 'm1');

  c.send({ v: 1, id: 'ls2', type: 'list_sessions' });
  const list2 = await c.waitFor(
      (f) => f.type === 'session_list' &&
          f.sessions.some((s) => s.id === id && s.name === 'my renamed session'),
      5000, 'session_list with the renamed entry');
  c.close();
});

test('delete_session removes the file and the list entry', async () => {
  mkdirSync(join(root, 'sessions'), { recursive: true });
  const id = 'test-delete-0001';
  const file = join(root, 'sessions', `${id}.jsonl`);
  writeFileSync(file, JSON.stringify({ type: 'session', id, version: 1, cwd: '/home/test/y', created_at: '2026-11-04T11:00:00Z' }) + '\n');

  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  c.send({ v: 1, id: 'ls1', type: 'list_sessions' });
  const list1 = await c.waitFor(
      (f) => f.type === 'session_list' && f.sessions.some((s) => s.id === id),
      5000, 'session_list containing the new file');

  c.send({ v: 1, id: 'del1', type: 'delete_session', session_id: id });
  const ok = await c.waitFor((f) => f.type === 'delete_session_response' && f.id === 'del1');
  assert.equal(ok.ok, true);
  assert.equal((await import('node:fs')).existsSync(file), false, 'file should be gone');

  c.send({ v: 1, id: 'ls2', type: 'list_sessions' });
  await c.waitFor(
      (f) => f.type === 'session_list' && !f.sessions.some((s) => s.id === id),
      5000, 'session_list without the deleted entry');
  c.close();
});

test('delete/rename of unknown session fail', async () => {
  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  c.send({ v: 1, id: 'del9', type: 'delete_session', session_id: 'nope' });
  const f1 = await c.waitFor((f) => f.type === 'delete_session_response' && f.id === 'del9');
  assert.equal(f1.ok, false);
  assert.match(f1.error, /unknown session/);
  c.send({ v: 1, id: 'rn9', type: 'rename_session', session_id: 'nope', name: 'x' });
  const f2 = await c.waitFor((f) => f.type === 'rename_session_response' && f.id === 'rn9');
  assert.equal(f2.ok, false);
  assert.match(f2.error, /unknown session/);
  c.close();
});

test('run_finished triggers a /notify POST with the owner message', async () => {
  // mock /notify endpoint
  const received = [];
  const http = await import('node:http');
  const mock = http.createServer((req, res) => {
    let body = '';
    req.on('data', (d) => (body += d));
    req.on('end', () => {
      received.push({ headers: req.headers, body: JSON.parse(body) });
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end('{"detail":"sent"}');
    });
  });
  await new Promise((r) => mock.listen(0, '127.0.0.1', r));
  const mockPort = mock.address().port;

  mkdirSync(join(root, 'notify-sessions'), { recursive: true });
  const notifyServer = new BabelServer({
    port: 0,
    bind: '127.0.0.1',
    token: 'nt',
    piBin: wrapper(),
    sessionDir: join(root, 'notify-sessions'),
    maxSessions: 1,
    notify: { url: `http://127.0.0.1:${mockPort}/notify`, key: 'test-key' },
    log: (m) => logs.push(m),
  });
  await notifyServer.start();
  const nport = notifyServer.wss.address().port;

  const cwd = mkdirSync(join(root, 'notify-cwd'), { recursive: true });
  const c = new Client(`ws://127.0.0.1:${nport}/ws?token=nt`);
  await c.connect();
  c.send({ v: 1, id: 'ns1', type: 'new_session', cwd: String(cwd), name: 'notify-test' });
  const created = await c.waitFor((f) => f.type === 'new_session_response' && f.id === 'ns1');
  const sid = created.session_id;
  c.send({ v: 1, id: 'nat1', type: 'attach', session_id: sid });
  await c.waitFor((f) => f.id === 'nat1');
  c.send({ v: 1, id: 'np1', type: 'prompt', session_id: sid, text: 'go' });
  await c.waitFor((f) => f.type === 'run_finished' && f.session_id === sid, 8000, 'run_finished');

  // notify is fire-and-forget — give it a moment
  for (let i = 0; i < 50 && received.length === 0; i++) {
    await new Promise((r) => setTimeout(r, 50));
  }
  assert.equal(received.length, 1, 'one notify POST expected');
  assert.equal(received[0].headers.authorization, 'Bearer test-key');
  assert.equal(received[0].body.alert, `babel-${sid}`);
  assert.match(received[0].body.message, /notify-test — run finished/);

  c.close();
  await notifyServer.stop();
  mock.close();
});

test('session_renamed updates the live list name', async () => {
  const rnServer = new BabelServer({
    port: 0,
    bind: '127.0.0.1',
    token: 'rn',
    piBin: wrapper({ FAKE_PI_NAME: 'Auto Generated Title' }),
    sessionDir: join(root, 'rn-sessions'),
    maxSessions: 1,
    log: (m) => logs.push(m),
  });
  mkdirSync(join(root, 'rn-sessions'), { recursive: true });
  await rnServer.start();
  const rport = rnServer.wss.address().port;

  const c = new Client(`ws://127.0.0.1:${rport}/ws?token=rn`);
  await c.connect();
  const cwd = mkdirSync(join(root, 'rn-cwd'), { recursive: true });
  c.send({ v: 1, id: 'rn1', type: 'new_session', cwd: String(cwd) });
  const created = await c.waitFor((f) => f.id === 'rn1');
  const sid = created.session_id;
  c.send({ v: 1, id: 'rn2', type: 'attach', session_id: sid });
  await c.waitFor((f) => f.id === 'rn2');

  // prompt → fake-pi settles → emits session_info_changed
  c.send({ v: 1, id: 'rn3', type: 'prompt', session_id: sid, text: 'go' });
  const renamed = await c.waitFor((f) => f.type === 'session_renamed' && f.session_id === sid, 8000, 'session_renamed');
  assert.equal(renamed.name, 'Auto Generated Title');

  // the live list now shows the generated name
  const list = await c.waitFor(
    (f) => f.type === 'session_list' && f.sessions.some((s) => s.id === sid && s.name === 'Auto Generated Title'),
    8000, 'updated session_list',
  );
  c.close();
  await rnServer.stop();
});

test('watchdog closes a hung run (no events during runActive)', async () => {
  // fake inhibit binary: a no-op that just sleeps
  const fakeInhibit = join(tmpdir(), `fake-inhibit-${Math.random().toString(16).slice(2)}.sh`);
  writeFileSync(fakeInhibit, '#!/usr/bin/env bash\nsleep 30\n');
  chmodSync(fakeInhibit, 0o755);

  const wdServer = new BabelServer({
    port: 0,
    bind: '127.0.0.1',
    token: 'wd',
    piBin: wrapper(),
    sessionDir: join(root, 'wd-sessions'),
    maxSessions: 1,
    runWatchdogMs: 300,
    watchdogTickMs: 50,
    inhibitBin: fakeInhibit,
    log: (m) => logs.push(m),
  });
  mkdirSync(join(root, 'wd-sessions'), { recursive: true });
  await wdServer.start();
  const wport = wdServer.wss.address().port;

  const c = new Client(`ws://127.0.0.1:${wport}/ws?token=wd`);
  await c.connect();
  const cwd = mkdirSync(join(root, 'wd-cwd'), { recursive: true });
  c.send({ v: 1, id: 'w1', type: 'new_session', cwd: String(cwd) });
  const created = await c.waitFor((f) => f.id === 'w1');
  const sid = created.session_id;
  c.send({ v: 1, id: 'w2', type: 'attach', session_id: sid });
  await c.waitFor((f) => f.id === 'w2'); // attach → getState → status idle
  const s = wdServer.sessions.get(sid);

  // Simulate a hung run: active run, stale last event.
  s.runActive = true;
  s.lastEventAt = Date.now() - 1000;

  const dead = await c.waitFor((f) => f.type === 'status' && f.session_id === sid && f.state === 'dead', 5000, 'watchdog dead');
  assert.ok(dead);
  c.close();
  await wdServer.stop();
});

test('inhibit lock follows the run lifecycle', async () => {
  // fake inhibit binary: touches a file while alive, removes it on exit
  const marker = join(tmpdir(), `inhibit-marker-${Math.random().toString(16).slice(2)}`);
  const fakeInhibit = join(tmpdir(), `fake-inhibit-${Math.random().toString(16).slice(2)}.sh`);
  // `sleep & wait` so a TERM trap fires immediately (bash defers traps
  // while a foreground child runs).
  writeFileSync(fakeInhibit, `#!/usr/bin/env bash\ntouch ${marker}\ntrap 'rm -f ${marker}; exit 0' TERM INT\nsleep 30 &\nwait\n`);
  chmodSync(fakeInhibit, 0o755);

  const inServer = new BabelServer({
    port: 0,
    bind: '127.0.0.1',
    token: 'in',
    // 3s runs: a window to observe the lock while the run is in flight
    piBin: wrapper({ FAKE_PI_RUN_MS: '3000' }),
    sessionDir: join(root, 'in-sessions'),
    maxSessions: 1,
    inhibitBin: fakeInhibit,
    log: (m) => logs.push(m),
  });
  mkdirSync(join(root, 'in-sessions'), { recursive: true });
  await inServer.start();
  const iport = inServer.wss.address().port;

  const c = new Client(`ws://127.0.0.1:${iport}/ws?token=in`);
  await c.connect();
  const cwd = mkdirSync(join(root, 'in-cwd'), { recursive: true });
  c.send({ v: 1, id: 'i1', type: 'new_session', cwd: String(cwd) });
  const created = await c.waitFor((f) => f.id === 'i1');
  const sid = created.session_id;
  c.send({ v: 1, id: 'i1a', type: 'attach', session_id: sid });
  await c.waitFor((f) => f.id === 'i1a');

  // idle session: no lock
  assert.equal(existsSync(marker), false, 'idle session should not hold the lock');

  // run in flight: lock appears
  c.send({ v: 1, id: 'i2', type: 'prompt', session_id: sid, text: 'go' });
  for (let i = 0; i < 100 && !existsSync(marker); i++) {
    await new Promise((r) => setTimeout(r, 50));
  }
  assert.ok(existsSync(marker), 'inhibit lock should be active while a run is in flight');

  // run finishes: lock released
  await c.waitFor((f) => f.type === 'run_finished' && f.session_id === sid, 8000, 'run_finished');
  for (let i = 0; i < 100 && existsSync(marker); i++) {
    await new Promise((r) => setTimeout(r, 50));
  }
  assert.equal(existsSync(marker), false, 'inhibit lock should release when the run finishes');
  c.close();
  await inServer.stop();
});

test('rejects bad token with 4401', async () => {
  await new Promise((resolve) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=wrong`);
    ws.on('close', (code) => { assert.equal(code, 4401); resolve(); });
    ws.on('error', () => resolve());
  });
});

test('rejects unsupported contract version with 4409', async () => {
  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  c.send({ v: 99, type: 'ping' });
  await new Promise((resolve) => {
    c.ws.on('close', (code) => { assert.equal(code, 4409); resolve(); });
  });
});

test('ping → pong', async () => {
  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  c.send({ v: 1, id: 'p1', type: 'ping' });
  const pong = await c.waitFor((f) => f.type === 'pong' && f.id === 'p1');
  assert.ok(pong);
  c.close();
});

test('hello + session_list arrive on connect', async () => {
  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  const hello = await c.waitFor((f) => f.type === 'hello');
  assert.equal(hello.server, 'babel-host');
  assert.equal(hello.contract, 1);
  await c.waitFor((f) => f.type === 'session_list');
  c.close();
});

test('new_session validates cwd', async () => {
  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  c.send({ v: 1, id: 'ns1', type: 'new_session', cwd: '/nonexistent-dir-xyz' });
  const r = await c.waitFor((f) => f.id === 'ns1');
  assert.equal(r.ok, false);
  assert.match(r.error, /cwd not found/);
  c.close();
});

test('new_session spawns and the session appears in the list', async () => {
  const cwd = mkdirSync(join(root, 'cwd1'), { recursive: true });
  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  c.send({ v: 1, id: 'ns2', type: 'new_session', cwd: String(cwd), name: 'unit-test' });
  const r = await c.waitFor((f) => f.id === 'ns2');
  assert.equal(r.ok, true, JSON.stringify(r));
  const sid = r.session_id;
  const list = await c.waitFor((f) => f.type === 'session_list' && f.sessions.some((s) => s.id === sid));
  const entry = list.sessions.find((s) => s.id === sid);
  assert.equal(entry.name, 'unit-test');
  c.close();
  // clean up: kill the session so later tests have headroom
  server.sessions.get(sid)?.close();
  server.sessions.delete(sid);
  await drainMap();
});

test('prompt to unknown session fails', async () => {
  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  c.send({ v: 1, id: 'pr1', type: 'prompt', session_id: 's_nope', text: 'hi' });
  const r = await c.waitFor((f) => f.id === 'pr1');
  assert.equal(r.ok, false);
  assert.match(r.error, /unknown session/);
  c.close();
});

test('attach to unknown session fails', async () => {
  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  c.send({ v: 1, id: 'at1', type: 'attach', session_id: 's_nope' });
  const r = await c.waitFor((f) => f.id === 'at1');
  assert.equal(r.ok, false);
  c.close();
});

test('prompt drives the live frame pipeline (fake-pi)', async () => {
  const cwd = mkdirSync(join(root, 'cwd2'), { recursive: true });
  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  c.send({ v: 1, id: 'ns3', type: 'new_session', cwd: String(cwd) });
  const ns = await c.waitFor((f) => f.id === 'ns3');
  const sid = ns.session_id;
  c.send({ v: 1, id: 'at2', type: 'attach', session_id: sid });
  await c.waitFor((f) => f.id === 'at2');
  c.send({ v: 1, id: 'pr2', type: 'prompt', session_id: sid, text: 'hello' });
  const pr = await c.waitFor((f) => f.id === 'pr2');
  assert.equal(pr.ok, true, JSON.stringify(pr));
  await c.waitFor((f) => f.type === 'run_started' && f.session_id === sid, 10000, 'run_started');
  const delta = await c.waitFor((f) => f.type === 'text_delta' && f.session_id === sid, 10000, 'text_delta');
  assert.equal(delta.delta, 'fake reply');
  await c.waitFor((f) => f.type === 'run_finished' && f.session_id === sid, 10000, 'run_finished');
  c.close();
  server.sessions.get(sid)?.close();
  server.sessions.delete(sid);
  await drainMap();
});

test('stored sessions appear with derived names; /tmp and collision files are skipped', async () => {
  const dir = join(root, 'sessions', '--test-cwd--');
  mkdirSync(dir, { recursive: true });
  // named via session_info
  writeFileSync(join(dir, '2026-01-01T00-00-00Z_stored-named.jsonl'),
    [
      '{"type":"session","version":3,"id":"stored-named","timestamp":"2026-01-01T00:00:00Z","cwd":"/test/cwd"}',
      '{"type":"session_info","id":"si1","parentId":null,"timestamp":"2026-01-01T00:00:01Z","name":"My Named Session"}',
    ].join('\n') + '\n');
  // unnamed — falls back to first user message
  writeFileSync(join(dir, '2026-01-02T00-00-00Z_stored-anon.jsonl'),
    [
      '{"type":"session","version":3,"id":"stored-anon","timestamp":"2026-01-02T00:00:00Z","cwd":"/test/cwd"}',
      '{"type":"message","id":"m1","parentId":null,"timestamp":"t","message":{"role":"user","content":"fix the thing","timestamp":1}}',
    ].join('\n') + '\n');
  // /tmp cwd — must be filtered
  mkdirSync(join(root, 'sessions', '--tmp-x--'), { recursive: true });
  writeFileSync(join(root, 'sessions', '--tmp-x--', '2026-01-03T00-00-00Z_stored-tmp.jsonl'),
    '{"type":"session","version":3,"id":"stored-tmp","timestamp":"2026-01-03T00:00:00Z","cwd":"/tmp/x"}\n');
  // collision file — must be skipped
  writeFileSync(join(dir, 'collision.jsonl'),
    '{"type":"session","version":3,"id":"collision-id","timestamp":"2026-01-04T00:00:00Z","cwd":"/test/cwd"}\n');

  // bust the 5s scan cache so the fresh files are seen
  server._storedCacheAt = 0;
  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  const list = await c.waitFor((f) => f.type === 'session_list' && f.sessions.some((s) => s.id === 'stored-named'));
  const named = list.sessions.find((s) => s.id === 'stored-named');
  assert.equal(named.status, 'stored');
  assert.equal(named.name, 'My Named Session');
  const anon = list.sessions.find((s) => s.id === 'stored-anon');
  assert.equal(anon.name, 'fix the thing');
  assert.ok(!list.sessions.some((s) => s.id === 'stored-tmp'), '/tmp session must be hidden');
  assert.ok(!list.sessions.some((s) => s.id === 'collision-id'), 'collision file must be skipped');
  c.close();
});

test('stored session: latest session_info at the END of a large file wins', async () => {
  const dir = join(root, 'sessions', '--test-cwd--');
  mkdirSync(dir, { recursive: true });
  const lines = [
    '{"type":"session","version":3,"id":"stored-big","timestamp":"2026-01-05T00:00:00Z","cwd":"/test/cwd"}',
    JSON.stringify({ type: 'message', id: 'm1', parentId: null, timestamp: 't', message: { role: 'user', content: 'first user message' } }),
    // pad past the 256KB head window
    JSON.stringify({ type: 'message', id: 'm2', parentId: 'm1', timestamp: 't', message: { role: 'toolResult', content: 'x'.repeat(300 * 1024) } }),
    '{"type":"session_info","id":"si1","parentId":"m2","timestamp":"2026-01-05T00:01:00Z","name":"old name"}',
    '{"type":"session_info","id":"si2","parentId":"si1","timestamp":"2026-01-05T00:02:00Z","name":"Renamed at the end"}',
  ];
  writeFileSync(join(dir, '2026-01-05T00-00-00Z_stored-big.jsonl'), lines.join('\n') + '\n');

  server._storedCacheAt = 0;
  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  const list = await c.waitFor((f) => f.type === 'session_list' && f.sessions.some((s) => s.id === 'stored-big'));
  const big = list.sessions.find((s) => s.id === 'stored-big');
  assert.equal(big.name, 'Renamed at the end');
  c.close();
});

test('stored session: name far from the end (long conversation after rename) is still found', async () => {
  // Regression: the 256KB tail window missed a name that was 695KB from the
  // end (a long session continued after /rename). The full-file marker
  // scan must find it at any distance.
  const dir = join(root, 'sessions', '--test-cwd--');
  mkdirSync(dir, { recursive: true });
  const lines = [
    '{"type":"session","version":3,"id":"stored-far","timestamp":"2026-01-07T00:00:00Z","cwd":"/test/cwd"}',
    JSON.stringify({ type: 'message', id: 'm1', parentId: null, timestamp: 't', message: { role: 'user', content: 'first user message' } }),
    '{"type":"session_info","id":"si1","parentId":"m1","timestamp":"2026-01-07T00:01:00Z","name":"Named early"}',
    // ~800KB of conversation AFTER the rename — past any fixed tail window
    JSON.stringify({ type: 'message', id: 'm2', parentId: 'si1', timestamp: 't', message: { role: 'assistant', content: 'y'.repeat(400 * 1024) } }),
    JSON.stringify({ type: 'message', id: 'm3', parentId: 'm2', timestamp: 't', message: { role: 'toolResult', content: 'z'.repeat(400 * 1024) } }),
  ];
  writeFileSync(join(dir, '2026-01-07T00-00-00Z_stored-far.jsonl'), lines.join('\n') + '\n');

  server._storedCacheAt = 0;
  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  const list = await c.waitFor((f) => f.type === 'session_list' && f.sessions.some((s) => s.id === 'stored-far'));
  const far = list.sessions.find((s) => s.id === 'stored-far');
  assert.equal(far.name, 'Named early');
  c.close();
});

test('mid-run prompt is sent as steer, not prompt', async () => {
  const dir = join(tmpdir(), `babel-steer-${Date.now()}`);
  mkdirSync(dir, { recursive: true });
  const logFile = join(dir, 'cmds.log');
  const s = new BabelServer({
    port: 0,
    bind: '127.0.0.1',
    token: 't',
    piBin: wrapper({ FAKE_PI_RUN_MS: '500', FAKE_PI_LOG: logFile }),
    sessionDir: join(dir, 'sessions'),
    log: () => {},
  });
  await s.start();
  const c = new Client(`ws://127.0.0.1:${s.wss.address().port}/ws?token=t`);
  await c.connect();
  c.send({ v: 1, id: 'ns1', type: 'new_session', cwd: dir });
  const ns = await c.waitFor((f) => f.type === 'new_session_response');
  const sid = ns.session_id;
  // attach — live frames only reach attached clients
  c.send({ v: 1, id: 'at1', type: 'attach', session_id: sid });
  await c.waitFor((f) => f.type === 'attach_response');
  c.send({ v: 1, id: 'p1', type: 'prompt', session_id: sid, text: 'first' });
  await c.waitFor((f) => f.type === 'run_started');
  // run is in flight (500ms) — this prompt must go out as a steer
  c.send({ v: 1, id: 'p2', type: 'prompt', session_id: sid, text: 'mid-run' });
  await c.waitFor((f) => f.type === 'run_finished');
  await new Promise((r) => setTimeout(r, 100));
  c.close();
  await s.stop();
  const { readFileSync } = await import('node:fs');
  const cmds = readFileSync(logFile, 'utf8').trim().split('\n');
  // get_state (from _waitReady) + prompt + steer — the mid-run one is a steer
  assert.ok(cmds.includes('prompt'), `expected a prompt in ${cmds}`);
  assert.ok(cmds.includes('steer'), `expected a steer in ${cmds}`);
  assert.equal(cmds.filter((x) => x === 'prompt').length, 1, 'only the first prompt is a prompt');
  rmSync(dir, { recursive: true, force: true });
});

test('rename_session chains parentId past a huge final line', async () => {
  const dir = join(root, 'sessions', '--test-cwd--');
  mkdirSync(dir, { recursive: true });
  const id = 'stored-hugeline';
  const file = join(dir, `${id}.jsonl`);
  const bigId = 'big-entry-0001';
  // last line is a 100KB tool result — past the old 64KB lastLine window
  writeFileSync(file, [
    '{"type":"session","version":3,"id":"' + id + '","timestamp":"2026-01-06T00:00:00Z","cwd":"/test/cwd"}',
    JSON.stringify({ type: 'message', id: bigId, parentId: null, timestamp: 't', message: { role: 'toolResult', content: 'y'.repeat(100 * 1024) } }),
  ].join('\n') + '\n');

  server._storedCacheAt = 0;
  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  c.send({ v: 1, id: 'rn1', type: 'rename_session', session_id: id, name: 'Hugeline Renamed' });
  await c.waitFor((f) => f.type === 'rename_session_response' && f.ok === true);
  c.close();

  const { readFileSync } = await import('node:fs');
  const lines = readFileSync(file, 'utf8').trim().split('\n');
  const appended = JSON.parse(lines[lines.length - 1]);
  assert.equal(appended.type, 'session_info');
  assert.equal(appended.name, 'Hugeline Renamed');
  assert.equal(appended.parentId, bigId, 'parentId must chain from the huge last entry');
});

test('dead sessions drop out of the list', async () => {
  const cwd = mkdirSync(join(root, 'cwd3'), { recursive: true });
  // swap in a dying pi binary
  const origBin = server.piBin;
  server.piBin = wrapper({ FAKE_PI_DIE: '1' });
  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  c.send({ v: 1, id: 'ns4', type: 'new_session', cwd: String(cwd) });
  const ns = await c.waitFor((f) => f.id === 'ns4');
  assert.equal(ns.ok, true);
  const sid = ns.session_id;
  // wait for the death to propagate out of the map (the connect-time
  // session_list in history would match a "not in list" predicate, so
  // poll the map directly)
  for (let i = 0; i < 200 && server.sessions.has(sid); i++) {
    await new Promise((r) => setTimeout(r, 50));
  }
  assert.ok(!server.sessions.has(sid), 'dead session must leave the map');
  server.piBin = origBin;
  c.close();
});

test('maxSessions is enforced', async () => {
  const cwd = mkdirSync(join(root, 'cwd4'), { recursive: true });
  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  // fill to the limit (maxSessions=2)
  const a = await new Promise((res) => {
    c.send({ v: 1, id: 'ns5', type: 'new_session', cwd: String(cwd) });
    c.onFrame = (f) => { if (f.id === 'ns5') { c.onFrame = undefined; res(f); } };
  });
  const b = await new Promise((res) => {
    c.send({ v: 1, id: 'ns6', type: 'new_session', cwd: String(cwd) });
    c.onFrame = (f) => { if (f.id === 'ns6') { c.onFrame = undefined; res(f); } };
  });
  assert.equal(a.ok, true);
  assert.equal(b.ok, true);
  const d = await new Promise((res) => {
    c.send({ v: 1, id: 'ns7', type: 'new_session', cwd: String(cwd) });
    c.onFrame = (f) => { if (f.id === 'ns7') { c.onFrame = undefined; res(f); } };
  });
  assert.equal(d.ok, false);
  assert.match(d.error, /max sessions/);
  c.close();
  for (const id of [a.session_id, b.session_id]) {
    server.sessions.get(id)?.close();
    server.sessions.delete(id);
  }
  await drainMap();
});

test('respond_input forwards extension_ui_response to pi', async () => {
  const { readFileSync } = await import('node:fs');
  const logFile = join(tmpdir(), `fake-pi-log-${Date.now()}.txt`);
  const s2 = new BabelServer({
    port: 0,
    bind: '127.0.0.1',
    token: 'test-token',
    piBin: wrapper({ FAKE_PI_LOG: logFile }),
    sessionDir: join(root, 'sessions-ri'),
    maxSessions: 2,
    toolResultMax: 4000,
    hostVersion: 'test',
    log: (m) => logs.push(m),
  });
  await s2.start();
  const c = new Client(`ws://127.0.0.1:${s2.wss.address().port}/ws?token=test-token`);
  await c.connect();
  const cwd = process.cwd();
  c.send({ v: 1, id: 'ns1', type: 'new_session', cwd: String(cwd) });
  const created = await c.waitFor((f) => f.type === 'new_session_response' && f.id === 'ns1');
  assert.equal(created.ok, true);
  const sid = created.session_id;

  // Answer a (fake) confirm dialog.
  c.send({ v: 1, id: 'ri1', type: 'respond_input', session_id: sid, request_id: 'req-xyz', confirmed: true });
  const resp = await c.waitFor((f) => f.type === 'respond_input_response' && f.id === 'ri1');
  assert.equal(resp.ok, true);
  await new Promise((r) => setTimeout(r, 150)); // let the child read stdin
  const logged = readFileSync(logFile, 'utf8').trim().split('\n');
  assert.ok(logged.includes('extension_ui_response'),
    `pi log should contain extension_ui_response, got: ${JSON.stringify(logged)}`);

  // value and cancelled forms are also forwarded.
  c.send({ v: 1, id: 'ri2', type: 'respond_input', session_id: sid, request_id: 'req-2', value: 'option-a' });
  await c.waitFor((f) => f.type === 'respond_input_response' && f.id === 'ri2');
  c.send({ v: 1, id: 'ri3', type: 'respond_input', session_id: sid, request_id: 'req-3', cancelled: true });
  await c.waitFor((f) => f.type === 'respond_input_response' && f.id === 'ri3');
  await new Promise((r) => setTimeout(r, 150));
  const logged2 = readFileSync(logFile, 'utf8').trim().split('\n');
  assert.equal(logged2.filter((l) => l === 'extension_ui_response').length, 3);

  // Missing answer fields → error.
  c.send({ v: 1, id: 'ri4', type: 'respond_input', session_id: sid, request_id: 'req-4' });
  const bad = await c.waitFor((f) => f.type === 'respond_input_response' && f.id === 'ri4');
  assert.equal(bad.ok, false);

  c.close();
  s2.sessions.get(sid)?.close();
  s2.sessions.delete(sid);
  await s2.stop();
});

test('attach to a stored session locked by a live process fails; stale lock passes', async () => {
  // cwd must exist (spawn) and not be under /tmp (stored-scan filter).
  const cwd = process.cwd();
  const dir = join(root, 'sessions', '--lock-cwd--');
  mkdirSync(dir, { recursive: true });
  const file = join(dir, '2026-01-05T00-00-00Z_stored-lock.jsonl');
  writeFileSync(file,
    JSON.stringify({ type: 'session', version: 3, id: 'stored-lock', timestamp: '2026-01-05T00:00:00Z', cwd: String(cwd) }) + '\n');
  const lockFile = `${file}.lock`;

  // Live lock (this process's pid is alive) → attach refused.
  writeFileSync(lockFile, JSON.stringify({ pid: process.pid, startedAt: 'now' }));
  server._storedCacheAt = 0;
  const c = new Client(`ws://127.0.0.1:${port}/ws?token=test-token`);
  await c.connect();
  c.send({ v: 1, id: 'at1', type: 'attach', session_id: 'stored-lock' });
  const denied = await c.waitFor((f) => f.type === 'attach_response' && f.id === 'at1');
  assert.equal(denied.ok, false);
  assert.match(denied.error, /open in another terminal/);

  // Stale lock (dead pid) → attach proceeds (fake-pi spawns).
  writeFileSync(lockFile, JSON.stringify({ pid: 999999, startedAt: 'now' }));
  c.send({ v: 1, id: 'at2', type: 'attach', session_id: 'stored-lock' });
  const ok = await c.waitFor((f) => f.type === 'attach_response' && f.id === 'at2');
  assert.equal(ok.ok, true);

  c.close();
  const s = server.sessions.get('stored-lock');
  if (s) { s.close(); server.sessions.delete('stored-lock'); }
  await drainMap();
  rmSync(lockFile, { force: true });
});
