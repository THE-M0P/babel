// WebSocket server: token auth, contract routing, client management.
//
// Contract: the JSON contract (v1, see project.mjs / app contract.dart).
// One attached session per
// connection (re-attach switches the live target).

import { WebSocketServer, WebSocket } from 'ws';
import { existsSync, readdirSync, statSync, openSync, readSync, closeSync, appendFileSync, readFileSync } from 'node:fs';
import { rmSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { randomBytes } from 'node:crypto';
import { Session, newSessionId } from './session.mjs';

/** Read the id of the last entry in a (potentially large) session file.
 *  Reads the tail 256KB and walks backwards to the last parseable line —
 *  a single huge tool result (>64KB) must not break the parent chain. */
/** True if a process with [pid] exists (signal-0 probe). */
function isPidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    // EPERM: alive but not ours; ESRCH: dead.
    return e.code === 'EPERM';
  }
}

function lastEntryId(path) {
  const size = statSync(path).size;
  const chunkSize = Math.min(size, 262144);
  const fd = openSync(path, 'r');
  try {
    const buf = Buffer.alloc(chunkSize);
    readSync(fd, buf, 0, chunkSize, size - chunkSize);
    const lines = buf.toString('utf8').split('\n');
    for (let i = lines.length - 1; i >= 0; i--) {
      if (!lines[i].trim()) continue;
      try {
        const e = JSON.parse(lines[i]);
        if (e && typeof e.id === 'string') return e.id;
      } catch { /* partial line (chunk boundary) — try the previous one */ }
    }
    return null;
  } finally {
    closeSync(fd);
  }
}

/** Append a session_info entry (display name) to a session file.
 *  parentId must chain from the last entry — pi validates the tree. */
function appendSessionInfo(path, name) {
  const parentId = lastEntryId(path);
  const entry = {
    type: 'session_info',
    id: randomBytes(4).toString('hex'),
    parentId,
    timestamp: new Date().toISOString(),
    name,
  };
  appendFileSync(path, JSON.stringify(entry) + '\n');
}

/** Find the LATEST session_info entry in a session file of any size.
 *  pi's getSessionName() walks entries in reverse; /rename and auto-titles
 *  append to the END of the file, and a long conversation after the rename
 *  pushes it arbitrarily far from the end (a fixed tail window keeps
 *  missing it). So scan the whole file for the marker — a cheap string
 *  search, no JSON parsing of non-matching lines — and parse only the one
 *  line that contains it. */
function latestSessionInfo(path) {
  const size = statSync(path).size;
  if (size === 0 || size > 64 * 1024 * 1024) return null; // sanity cap
  const buf = Buffer.alloc(size);
  const fd = openSync(path, 'r');
  try {
    readSync(fd, buf, 0, size, 0);
  } finally {
    closeSync(fd);
  }
  const MARKER = '"type":"session_info"';
  const text = buf.toString('utf8');
  const idx = text.lastIndexOf(MARKER);
  if (idx === -1) return null;
  const start = text.lastIndexOf('\n', idx) + 1;
  const end = text.indexOf('\n', idx);
  let e;
  try { e = JSON.parse(text.slice(start, end === -1 ? text.length : end)); } catch { return null; }
  return e.type === 'session_info' ? e : null;
}

/** Read the metadata of a (potentially large) session file:
 *  - header: the first line
 *  - name: the latest session_info entry (full-file marker scan — see
 *    latestSessionInfo; a tail window misses names on long sessions)
 *  - firstUser: the first user message (fallback display name) */
function sessionHead(path, maxBytes = 262144) {
  const size = statSync(path).size;
  const fd = openSync(path, 'r');
  try {
    const parse = (line) => { try { return JSON.parse(line); } catch { return null; } };
    const userText = (c) => typeof c === 'string' ? c
      : Array.isArray(c) ? c.filter((b) => b?.type === 'text').map((b) => b.text).join(' ')
      : '';

    let header = null, firstUser = null;

    // Head: header + first user message. Both live near the start, so
    // stop as soon as both are found.
    const headLen = Math.min(maxBytes, size);
    const headBuf = Buffer.alloc(headLen);
    readSync(fd, headBuf, 0, headLen, 0);
    for (const line of headBuf.toString('utf8').split('\n')) {
      if (!line) continue;
      const e = parse(line);
      if (!e) continue;
      if (e.type === 'session' && !header) header = e;
      if (!firstUser && e.type === 'message' && e.message?.role === 'user') {
        firstUser = userText(e.message.content);
      }
      if (header && firstUser) break;
    }

    // Name: latest session_info anywhere in the file. Mirrors pi — the
    // latest entry decides, and an empty name clears it.
    const info = latestSessionInfo(path);
    const name = info ? (info.name?.trim() || null) : null;

    return { header, name, firstUser };
  } finally {
    closeSync(fd);
  }
}

const CONTRACT_VERSION = 1;
const IDLE_TIMEOUT_MS = 60_000;
const PING_INTERVAL_MS = 20_000;
// Watchdog: a run with no pi events for this long is hung (dead LLM, wedged
// tool) — close the session so the user gets a dead state + notification
// instead of an eternal spinner.
const RUN_WATCHDOG_MS = 120_000;
const WATCHDOG_TICK_MS = 30_000;

export class BabelServer {
  /**
   * @param {object} opts {port, bind, token, piBin, sessionDir, maxSessions,
   *                       toolResultMax, hostVersion, log}
   */
  constructor(opts) {
    this.port = opts.port;
    this.bind = opts.bind;
    this.token = opts.token;
    this.piBin = opts.piBin;
    this.sessionDir = opts.sessionDir;
    this.maxSessions = opts.maxSessions ?? 4;
    this.toolResultMax = opts.toolResultMax ?? 4000;
    this.hostVersion = opts.hostVersion ?? '0.1.0';
    this.log = opts.log ?? (() => {});
    // {url, key} — POST run_finished/error alerts to a /notify endpoint.
    // Absent → notifications disabled (host still works).
    this.notifyCfg = opts.notify ?? null;
    // Watchdog + inhibit knobs (tests shorten/replace them).
    this.runWatchdogMs = opts.runWatchdogMs ?? RUN_WATCHDOG_MS;
    this.watchdogTickMs = opts.watchdogTickMs ?? WATCHDOG_TICK_MS;
    this.inhibitBin = opts.inhibitBin ?? 'systemd-inhibit';

    this.sessions = new Map(); // id -> Session
    this.clients = new Map(); // raw ws -> client wrapper
    this.wss = null;
  }

  /** Wait for a session's pi child to exit (bounded — close() SIGKILLs at
   *  5s, so the file flush is done by then). */
  _awaitExit(s, timeoutMs = 6000) {
    return new Promise((resolve) => {
      const t = setTimeout(resolve, timeoutMs);
      t.unref?.();
      s.onExit(() => { clearTimeout(t); resolve(); });
    });
  }

  async start() {
    this.wss = new WebSocketServer({ host: this.bind, port: this.port });
    this.wss.on('connection', (ws, req) => this._onConnection(ws, req));
    this.wss.on('error', (e) => this.log(`ws server error: ${e.message}`));
    await new Promise((resolve, reject) => {
      this.wss.once('listening', resolve);
      this.wss.once('error', reject);
    });
    this.log(`listening on ws://${this.bind}:${this.port}`);
    this._startWatchdog();
  }

  async stop() {
    if (this._watchdogTimer) clearInterval(this._watchdogTimer);
    for (const s of this.sessions.values()) s.close();
    this.sessions.clear();
    this._stopInhibit();
    for (const client of this.clients.values()) client.ws.close(1001);
    this.clients.clear();
    await new Promise((resolve) => this.wss?.close(resolve));
  }

  /** Close runs that have produced no events for RUN_WATCHDOG_MS. */
  _startWatchdog() {
    this._watchdogTimer = setInterval(() => {
      for (const s of this.sessions.values()) {
        if (s.status === 'dead' || s.status === 'starting' || !s.runActive) continue;
        const gap = Date.now() - s.lastEventAt;
        if (gap < this.runWatchdogMs) continue;
        const label = s.name || s.id.slice(0, 8);
        this.log(`[${s.id}] watchdog: no events for ${Math.round(gap / 1000)}s during a run — closing`);
        this._notify(`babel: ${label} — no activity for ${Math.round(this.runWatchdogMs / 1000)}s, session closed`, `babel-${s.id}`);
        s.close(); // → status:dead → frame sink drops it + updates inhibit
      }
    }, this.watchdogTickMs);
    this._watchdogTimer.unref?.();
  }

  /** Hold a systemd sleep-inhibit lock while any run is in flight, so a
   *  laptop lid close / suspend mid-run doesn't kill the pi child. Idle
   *  sessions don't hold the lock — an abandoned session shouldn't keep the
   *  laptop awake. The lock child lives in this service's cgroup, so it dies
   *  with the host. */
  _updateInhibit() {
    const anyRunning = [...this.sessions.values()].some((s) => s.runActive);
    if (anyRunning) this._startInhibit();
    else this._stopInhibit();
  }

  _startInhibit() {
    if (this._inhibitChild) return;
    try {
      this._inhibitChild = spawn(
        this.inhibitBin,
        ['--what=sleep', '--who=babel-host', '--mode=block',
         '--why=babel: agent run in flight',
         'sleep', 'infinity'],
        { stdio: 'ignore' },
      );
      this._inhibitChild.on('exit', (code) => {
        this.log(`inhibit lock exited (code=${code})`);
        this._inhibitChild = null;
      });
      this.log('sleep-inhibit lock active (run in flight)');
    } catch (e) {
      this.log(`inhibit failed: ${e.message}`);
      this._inhibitChild = null;
    }
  }

  _stopInhibit() {
    if (!this._inhibitChild) return;
    this._inhibitChild.kill('SIGTERM');
    this._inhibitChild = null;
    this.log('sleep-inhibit lock released');
  }

  _onConnection(ws, req) {
    const url = new URL(req.url, 'http://localhost');
    if (url.searchParams.get('token') !== this.token) {
      this.log(`auth failure from ${req.socket.remoteAddress}`);
      ws.close(4401, 'unauthorized');
      return;
    }

    const client = {
      ws,
      attached: null, // session id
      lastActivity: Date.now(),
      alive: true,
    };
    this.clients.set(ws, client);
    ws.on('message', (data) => {
      client.lastActivity = Date.now();
      this._onFrame(client, data.toString('utf8'));
    });
    ws.on('close', () => {
      client.attached = null;
      this.clients.delete(ws);
    });
    ws.on('error', (e) => this.log(`client error: ${e.message}`));

    this._send(client, { type: 'hello', server: 'babel-host', host_version: this.hostVersion, contract: CONTRACT_VERSION });
    this._sendSessionList(client);

    const hb = setInterval(() => {
      if (!client.alive) return clearInterval(hb);
      client.alive = false;
      try { ws.ping(); } catch { /* closing */ }
      if (Date.now() - client.lastActivity > IDLE_TIMEOUT_MS) {
        this.log(`idle timeout, closing client`);
        ws.close(1000, 'idle');
      }
    }, PING_INTERVAL_MS);
    ws.on('pong', () => { client.alive = true; });
    ws.on('close', () => clearInterval(hb));
  }

  _send(client, frame) {
    if (client.ws.readyState !== WebSocket.OPEN) return;
    client.ws.send(JSON.stringify({ v: CONTRACT_VERSION, ...frame }));
  }

  _sendSessionList(client) {
    this._send(client, { type: 'session_list', sessions: this._sessionList() });
  }

  _broadcastSessionList() {
    for (const client of this.clients.values()) {
      if (client.ws.readyState === WebSocket.OPEN) this._sendSessionList(client);
    }
  }

  /** Scan session dirs on disk for stored (non-live) sessions.
   *  Results are cached for 5s — the list is broadcast on every status change. */
  scanStoredSessions() {
    const now = Date.now();
    if (this._storedCache && now - this._storedCacheAt < 5000) return this._storedCache;
    const bases = [
      join(homedir(), '.deepthought', 'agent', 'sessions'), // deepthought fork TUI sessions
      join(homedir(), '.pi', 'agent', 'sessions'), // upstream pi TUI sessions
      this.sessionDir, // host-spawned sessions
    ];
    const seen = new Set();
    const out = [];
    for (const base of bases) {
      // Two layouts: the default dir organizes sessions into --<cwd>--
      // subdirs; an explicit --session-dir gets files directly in it.
      const dirs = [''];
      try {
        dirs.push(...readdirSync(base, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name));
      } catch {
        continue;
      }
      for (const sub of dirs) {
        let files = [];
        try {
          files = readdirSync(sub ? join(base, sub) : base).filter((f) => f.endsWith('.jsonl') && !f.startsWith('collision'));
        } catch {
          continue;
        }
        for (const f of files) {
          const path = join(base, sub, f);
          try {
            const { header, name, firstUser } = sessionHead(path);
            if (!header || header.type !== 'session' || seen.has(header.id)) continue;
            if (header.cwd?.startsWith('/tmp/')) continue; // test scratch sessions
            seen.add(header.id);
            const mtime = statSync(path).mtime;
            const display = name
              ?? (firstUser ? firstUser.trim().split('\n')[0].slice(0, 50) : null)
              ?? mtime.toLocaleString('en-US', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
            out.push({
              id: header.id,
              cwd: header.cwd ?? '',
              name: display,
              updated_at: mtime.toISOString(),
              // which base dir holds the file — resume needs to point pi at it
              base,
              path,
            });
          } catch {
            // unreadable/corrupt file — skip
          }
        }
      }
    }
    out.sort((a, b) => b.updated_at.localeCompare(a.updated_at));
    this._storedCache = out;
    this._storedCacheAt = now;
    return out;
  }

  _sessionList() {
    const live = [...this.sessions.values()].map((s) => ({
      id: s.id,
      name: s.name,
      cwd: s.cwd,
      status: s.status,
      model: s.model,
      updated_at: new Date().toISOString(),
    }));
    const liveIds = new Set(live.map((s) => s.id));
    const stored = this.scanStoredSessions()
      .filter((s) => !liveIds.has(s.id))
      .map((s) => ({ ...s, status: 'stored', model: null }));
    return [...live, ...stored];
  }

  /** Route one client frame. */
  async _onFrame(client, raw) {
    let frame;
    try {
      frame = JSON.parse(raw);
    } catch {
      this._send(client, { type: 'error', message: 'invalid JSON' });
      return;
    }
    if (typeof frame?.v !== 'number' || frame.v < 1 || frame.v > CONTRACT_VERSION) {
      if (client.ws.readyState === WebSocket.OPEN) client.ws.close(4409, 'unsupported contract version');
      return;
    }

    const reply = (extra = {}) =>
      this._send(client, { id: frame.id, type: `${frame.type}_response`, ok: true, ...extra });
    const fail = (error) =>
      this._send(client, { id: frame.id, type: `${frame.type}_response`, ok: false, error });

    try {
      switch (frame.type) {
        case 'ping':
          this._send(client, { type: 'pong', id: frame.id });
          return;

        case 'list_sessions':
          // explicit refresh — bust the 5s stored-scan cache
          this._storedCacheAt = 0;
          this._sendSessionList(client);
          reply();
          return;

        case 'attach': {
          if (!frame.session_id) {
            this._sendSessionList(client);
            reply();
            return;
          }
          let s = this.sessions.get(frame.session_id);
          if (!s) {
            // Stored session — resume it by spawning pi against the file.
            const stored = this.scanStoredSessions().find((x) => x.id === frame.session_id);
            if (!stored) { fail(`unknown session ${frame.session_id}`); return; }
            // One writer per session file: a live pi process (e.g. the TUI)
            // may have this session open. Two writers diverge — the TUI
            // never sees our appends. Refuse with a clear message.
            const lockFile = `${stored.path}.lock`;
            if (existsSync(lockFile)) {
              let lockPid;
              try { lockPid = JSON.parse(readFileSync(lockFile, 'utf8')).pid; } catch { /* stale */ }
              if (lockPid && isPidAlive(lockPid)) {
                fail(`session is open in another terminal (pid ${lockPid}) — close it there, then attach`);
                return;
              }
            }
            if (this.sessions.size >= this.maxSessions) {
              fail(`max sessions (${this.maxSessions}) reached`);
              return;
            }
            s = this._spawnSession(stored.id, stored.name ?? stored.id.slice(0, 8), stored.cwd, {
              resumeFrom: stored.id,
              // null for pi's own default dir (pi finds it there without the
              // flag); both the fork's and upstream's defaults qualify.
              sessionBase: [join(homedir(), '.deepthought', 'agent', 'sessions'),
                            join(homedir(), '.pi', 'agent', 'sessions')]
                .includes(stored.base) ? null : stored.base,
            });
            this.sessions.set(s.id, s);
            this._broadcastSessionList();
            this._updateInhibit();
          }
          client.attached = s.id;
          if (s.status === 'starting') await this._waitReady(s, 20_000);
          const t = await s.transcript();
          this._send(client, { type: 'transcript', ...t });
          reply();
          return;
        }

        case 'delete_session': {
          const id = frame.session_id;
          const live = this.sessions.get(id);
          if (!live) {
            const stored = this.scanStoredSessions().find((x) => x.id === id);
            if (!stored) { fail(`unknown session ${id}`); return; }
            rmSync(stored.path, { force: true });
          } else {
            live.close();
            this.sessions.delete(id);
            // Wait for pi's graceful exit so it finishes flushing the session
            // file — rm'ing mid-flush lets the child recreate the file and a
            // ghost session reappears in the list.
            await this._awaitExit(live);
            const stored = this.scanStoredSessions().find((x) => x.id === id);
            if (stored) rmSync(stored.path, { force: true });
          }
          this._storedCacheAt = 0;
          this._broadcastSessionList();
          this._updateInhibit();
          reply();
          return;
        }

        case 'rename_session': {
          const id = frame.session_id;
          const name = (frame.name ?? '').trim();
          if (!name) { fail('empty name'); return; }
          if (this.sessions.has(id)) {
            fail('session is live — abort it first, then rename');
            return;
          }
          const stored = this.scanStoredSessions().find((x) => x.id === id);
          if (!stored) { fail(`unknown session ${id}`); return; }
          appendSessionInfo(stored.path, name);
          this._storedCacheAt = 0;
          this._broadcastSessionList();
          reply();
          return;
        }

        case 'resnapshot': {
          const s = this.sessions.get(frame.session_id);
          if (!s) { fail(`unknown session ${frame.session_id}`); return; }
          const t = await s.transcript();
          this._send(client, { type: 'transcript', ...t });
          reply();
          return;
        }

        case 'new_session': {
          if (!frame.cwd || !existsSync(frame.cwd) || !statSync(frame.cwd).isDirectory()) {
            fail(`cwd not found: ${frame.cwd}`);
            return;
          }
          if (this.sessions.size >= this.maxSessions) {
            fail(`max sessions (${this.maxSessions}) reached`);
            return;
          }
          const id = newSessionId();
          const explicitName = (frame.name ?? '').trim();
          // Display name falls back to the cwd basename; pi only gets an
          // explicit name when the user supplied one (so pi's auto-naming
          // can fill the blank after the first run).
          const name = explicitName || frame.cwd.split('/').filter(Boolean).pop() || 'session';
          const s = this._spawnSession(id, name, frame.cwd, { explicitName: explicitName || null });
          this.sessions.set(id, s);
          this._broadcastSessionList();
          this._updateInhibit();
          reply({ session_id: id });
          if (frame.first_prompt) {
            // Give the child a moment to come up before the first prompt.
            await this._waitReady(s, 15_000);
            await this._prompt(s, frame.first_prompt);
          }
          return;
        }

        case 'prompt':
        case 'steer': {
          const s = this.sessions.get(frame.session_id);
          if (!s) { fail(`unknown session ${frame.session_id}`); return; }
          if (!frame.text?.trim()) { fail('empty text'); return; }
          if (s.status === 'dead') { fail('session is dead'); return; }
          if (frame.type === 'steer') {
            await s.request('steer', { message: frame.text });
          } else {
            await this._prompt(s, frame.text);
          }
          reply();
          return;
        }

        case 'abort': {
          const s = this.sessions.get(frame.session_id);
          if (!s) { fail(`unknown session ${frame.session_id}`); return; }
          await s.request('abort');
          reply();
          return;
        }

        case 'respond_input': {
          const s = this.sessions.get(frame.session_id);
          if (!s) { fail(`unknown session ${frame.session_id}`); return; }
          if (!frame.request_id) { fail('missing request_id'); return; }
          const resp = { type: 'extension_ui_response', id: frame.request_id };
          if (typeof frame.confirmed === 'boolean') resp.confirmed = frame.confirmed;
          else if (typeof frame.value === 'string') resp.value = frame.value;
          else if (frame.cancelled === true) resp.cancelled = true;
          else { fail('respond_input needs confirmed, value, or cancelled'); return; }
          // Fire-and-forget: pi resolves the blocked dialog; no response record.
          s.sendRaw(resp);
          reply();
          return;
        }

        default:
          fail(`unknown frame type: ${frame.type}`);
      }
    } catch (e) {
      this.log(`[${frame.type}] error: ${e.message}`);
      fail(e.message);
    }
  }

  _spawnSession(id, name, cwd, extra = {}) {
    const s = new Session({
      id, name, cwd,
      piBin: this.piBin, sessionDir: this.sessionDir,
      toolResultMax: this.toolResultMax, log: this.log,
      ...extra,
    });
    // Frame sink must be installed BEFORE spawn: a child that dies during
    // spawn (ENOENT etc.) emits status:dead synchronously from the error
    // handler, and a missed dead frame leaves a zombie in the session list.
    s.setOnFrames((frames) => {
      for (const f of frames) this._sendToSession(s.id, f);
      // pi named the session (auto-title / /name / /rename) — refresh the
      // live list entry.
      for (const f of frames) {
        if (f?.type === 'session_renamed' && f.name) {
          s.name = f.name;
          this._broadcastSessionList();
        }
      }
      if (frames.some((f) => f?.type === 'status' && f.state === 'dead')) {
        this.sessions.delete(s.id); // dead sessions drop out; stored files remain on disk
        this._updateInhibit();
      }
      if (frames.some((f) => f?.type === 'status')) this._broadcastSessionList();
      // Run state changes drive the sleep-inhibit lock.
      if (frames.some((f) => f?.type === 'run_started' || f?.type === 'run_finished')) {
        this._updateInhibit();
      }
      // Notifications: run completion and errors ping the owner (Signal via
      // /notify endpoint). Fire-and-forget — a notify failure must never
      // disturb the frame pipeline.
      for (const f of frames) {
        if (f?.type === 'run_finished') {
          const label = s.name || s.id.slice(0, 8);
          this._notify(
            f.aborted
              ? `babel: ${label} — run aborted`
              : `babel: ${label} — run finished`,
            `babel-${s.id}`,
          );
        } else if (f?.type === 'error') {
          const label = s.name || s.id.slice(0, 8);
          this._notify(`babel: ${label} — error: ${f.message ?? 'unknown'}`, `babel-${s.id}`);
        }
      }
    });
    s.spawn();
    return s;
  }

  /** POST an alert to a /notify endpoint (per-alert cooldown lives there). */
  _notify(message, alertKey) {
    if (!this.notifyCfg?.url) return;
    fetch(this.notifyCfg.url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${this.notifyCfg.key ?? ''}`,
      },
      body: JSON.stringify({ alert: alertKey, message }),
    }).then((r) => {
      if (!r.ok) this.log(`notify ${r.status}: ${r.statusText}`);
    }).catch((e) => this.log(`notify failed: ${e.message}`));
  }

  /** prompt, mapped to steer while a run is active (contract: one button).
   *  Uses runActive (fresh — driven by run_started/run_finished frames),
   *  NOT isStreaming (stale — only refreshed on get_state). A stale
   *  isStreaming made mid-run prompts hit pi's "Agent is already
   *  processing" error. The catch covers attaching mid-run, where
   *  runActive is stale-false. */
  async _prompt(s, text) {
    if (s.status === 'starting') {
      await this._waitReady(s, 15_000);
    }
    try {
      if (s.runActive) {
        await s.request('steer', { message: text });
      } else {
        await s.request('prompt', { message: text });
      }
    } catch (e) {
      if (/already processing/i.test(e.message ?? '')) {
        await s.request('steer', { message: text });
        return;
      }
      throw e;
    }
  }

  async _waitReady(s, timeoutMs) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      if (s.status === 'dead') throw new Error('session process exited during startup');
      try {
        await s.getState();
        return;
      } catch {
        await new Promise((r) => setTimeout(r, 250));
      }
    }
    throw new Error('session did not become ready in time');
  }

  _sendToSession(sessionId, frame) {
    for (const client of this.clients.values()) {
      if (client.attached === sessionId && client.ws.readyState === WebSocket.OPEN) {
        this._send(client, frame);
      }
    }
  }
}
