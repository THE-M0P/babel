// One deepthought (pi --mode rpc) child process + its RPC state.

import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { JsonlFramer } from './framing.mjs';
import { projectEvent } from './project.mjs';
import { projectTranscript } from './transcript.mjs';

const REQUEST_TIMEOUT_MS = 60_000;

export class Session {
  /**
   * @param {object} opts {id, name, cwd, piBin, sessionDir, toolResultMax, log}
   */
  /**
   * @param {object} opts {id, name, cwd, piBin, sessionDir, toolResultMax, log,
   *                       resumeFrom?} — resumeFrom: open an existing session
   *                       file by id instead of creating a new one
   */
  constructor(opts) {
    this.id = opts.id;
    this.name = opts.name;
    this.cwd = opts.cwd;
    this.piBin = opts.piBin;
    this.sessionDir = opts.sessionDir;
    this.toolResultMax = opts.toolResultMax ?? 4000;
    this.log = opts.log ?? (() => {});
    this.resumeFrom = opts.resumeFrom ?? null;
    this.sessionBase = opts.sessionBase ?? null;
    // The user-supplied name (passed to pi as --name). The display name
    // (this.name) may be a host-derived fallback (cwd basename) — pi should
    // only get an explicit name so its auto-naming can fill the blank.
    this.explicitName = opts.explicitName ?? null;

    this.status = 'starting'; // starting | running | idle | dead
    this.model = '';
    this.sessionFile = '';
    this.isStreaming = false;
    // Watchdog: when the last stdout record / RPC response arrived, and
    // whether a run is in flight (only runs can hang — an idle session
    // waiting for a prompt is not stuck).
    this.lastEventAt = Date.now();
    this.runActive = false;

    this._framer = new JsonlFramer();
    this._pending = new Map(); // request id -> {resolve, reject, timer}
    this._reqSeq = 0;
    this._ctx = { session_id: this.id, runId: null, nextRunId: 1, nextSeq: 1, toolResultMax: this.toolResultMax };
    this._onFrames = null; // (frames) => void, set by the server
    this._child = null;
  }

  /** The server installs a frame sink for this session's live frames. */
  setOnFrames(fn) {
    this._onFrames = fn;
  }

  /** Register a callback fired once when the child exits (immediately if
   *  already dead). Used to wait for pi's graceful file flush before
   *  deleting a session file. */
  onExit(cb) {
    if (this.status === 'dead') { cb(); return; }
    this._onExit = cb;
  }

  spawn() {
    const args = ['--mode', 'rpc'];
    if (this.resumeFrom) {
      // Open an existing session file (id resolved against cwd's project dir).
      args.push('--session', this.resumeFrom);
      if (this.sessionBase) args.push('--session-dir', this.sessionBase);
    } else {
      args.push('--session-id', this.id, '--session-dir', this.sessionDir);
      if (this.explicitName) args.push('--name', this.explicitName);
    }
    this._child = spawn(this.piBin, args, {
      cwd: this.cwd,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: process.env,
    });
    this._child.stdout.on('data', (chunk) => this._onStdout(chunk));
    this._child.stderr.on('data', (chunk) => {
      const s = chunk.toString('utf8').trim();
      if (s) this.log(`[${this.id}] pi stderr: ${s.slice(0, 500)}`);
    });
    this._child.on('exit', (code, signal) => {
      this.log(`[${this.id}] pi exited (code=${code} signal=${signal})`);
      this._die();
    });
    this._child.on('error', (e) => {
      this.log(`[${this.id}] pi spawn error: ${e.message}`);
      this._die();
    });
    return this;
  }

  _die() {
    if (this.status === 'dead') return;
    this.status = 'dead';
    for (const { reject, timer } of this._pending.values()) {
      clearTimeout(timer);
      reject(new Error('session process exited'));
    }
    this._pending.clear();
    this._onFrames?.([{ session_id: this.id, seq: this._ctx.nextSeq++, type: 'status', state: 'dead' }]);
    const cb = this._onExit;
    this._onExit = null;
    cb?.();
  }

  _onStdout(chunk) {
    this.lastEventAt = Date.now();
    for (const rec of this._framer.push(chunk)) {
      if (rec.__parse_error) {
        this.log(`[${this.id}] unparseable stdout record: ${rec.__parse_error}`);
        continue;
      }
      if (rec.type === 'response') {
        this._onResponse(rec);
      } else {
        const frames = projectEvent(rec, this._ctx);
        for (const f of frames) {
          if (f?.type === 'run_started') this.runActive = true;
          if (f?.type === 'run_finished') this.runActive = false;
        }
        if (frames.length) this._onFrames?.(frames);
      }
    }
  }

  _onResponse(rec) {
    const id = rec.id;
    if (id == null || !this._pending.has(id)) return; // unsolicited / stale
    this.lastEventAt = Date.now();
    const { resolve, reject, timer } = this._pending.get(id);
    this._pending.delete(id);
    clearTimeout(timer);
    if (rec.success) resolve(rec.data ?? {});
    else reject(new Error(rec.error ?? `command ${rec.command} failed`));
  }

  /** Write a raw record to pi's stdin without expecting a response.
   *  Used for extension_ui_response — pi resolves the pending dialog
   *  internally and emits no response record. */
  sendRaw(obj) {
    if (this.status === 'dead') throw new Error('session is dead');
    this._child.stdin.write(JSON.stringify(obj) + '\n');
  }

  /** Send an RPC command and await its response. */
  request(type, fields = {}, timeoutMs = REQUEST_TIMEOUT_MS) {
    if (this.status === 'dead') return Promise.reject(new Error('session is dead'));
    const id = `b${++this._reqSeq}`;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this._pending.delete(id);
        reject(new Error(`${type} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this._pending.set(id, { resolve, reject, timer });
      this._child.stdin.write(JSON.stringify({ id, type, ...fields }) + '\n');
    });
  }

  /** Current state from pi (model, isStreaming, sessionFile, ...). */
  async getState() {
    const data = await this.request('get_state');
    this.model = data.model?.id ?? this.model;
    this.sessionFile = data.sessionFile ?? this.sessionFile;
    this.isStreaming = !!data.isStreaming;
    if (this.status === 'starting') this.status = 'idle'; // first successful state = ready
    return data;
  }

  /** Contract transcript: full entry projection + current seq + metadata. */
  async transcript() {
    if (!this.model) {
      try { await this.getState(); } catch { /* model stays empty */ }
    }
    const data = await this.request('get_entries');
    const entries = projectTranscript(data.entries ?? [], this.toolResultMax);
    return {
      session_id: this.id,
      seq: this._ctx.nextSeq,
      entries,
      model: this.model || null,
      started_at: data.entries?.[0]?.timestamp ?? null,
      session_file: this.sessionFile || null,
    };
  }

  close() {
    if (!this._child) return;
    // SIGTERM only: pi's SIGTERM handler does a graceful dispose (which
    // flushes the session file). Do NOT also end stdin — EOF triggers the
    // same async shutdown, and the second signal then hits the
    // "already shutting down" fast path and process.exit()s mid-dispose,
    // losing the session file.
    this._child.kill('SIGTERM');
    const t = setTimeout(() => this._child?.kill('SIGKILL'), 5000);
    t.unref?.(); // don't hold the host's shutdown open for 5s
    this._child.once('exit', () => clearTimeout(t));
  }
}

export function newSessionId() {
  return `s_${randomUUID().slice(0, 12)}`;
}
