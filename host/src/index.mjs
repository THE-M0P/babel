// babel-host entrypoint: config, token, server, lifecycle.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { randomBytes } from 'node:crypto';
import { BabelServer } from './server.mjs';

const log = (msg) => console.log(`[babel-host] ${msg}`);

function loadConfig() {
  const dir = join(homedir(), '.config', 'babel');
  const file = join(dir, 'config.json');
  let cfg = {};
  if (existsSync(file)) {
    try { cfg = JSON.parse(readFileSync(file, 'utf8')); } catch (e) {
      log(`config parse error (${e.message}), using defaults`);
    }
  }
  const defaults = {
    port: 8790,
    // 127.0.0.0/8 is safe by default; set your tailnet IP in config.json so
    // the phone can reach the host.
    bind: '127.0.0.1',
    pi_bin: 'pi', // any pi binary with --mode rpc (pi.dev, or a fork)
    session_dir: join(homedir(), '.local', 'share', 'babel', 'sessions'),
    max_sessions: 4,
    tool_result_max_chars: 4000,
  };
  return { ...defaults, ...cfg };
}

function loadToken() {
  const dir = join(homedir(), '.config', 'babel');
  mkdirSync(dir, { recursive: true });
  const file = join(dir, 'token');
  if (!existsSync(file)) {
    writeFileSync(file, randomBytes(32).toString('hex'), { mode: 0o600 });
    log(`generated token at ${file}`);
  }
  return readFileSync(file, 'utf8').trim();
}

const cfg = loadConfig();
const token = loadToken();

// Allow ~ in config paths (session_dir).
if (cfg.session_dir?.startsWith('~')) {
  cfg.session_dir = join(homedir(), cfg.session_dir.slice(1));
}

mkdirSync(cfg.session_dir, { recursive: true });

const server = new BabelServer({
  port: cfg.port,
  bind: cfg.bind,
  token,
  piBin: cfg.pi_bin,
  sessionDir: cfg.session_dir,
  maxSessions: cfg.max_sessions,
  toolResultMax: cfg.tool_result_max_chars,
  hostVersion: '0.1.0',
  log,
  // {url, key} for a /notify endpoint (e.g. your assistant) — run_finished/error pings.
  // Omitted in config.json → notifications off.
  notify: cfg.notify ?? null,
});

let shuttingDown = false;
async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  log(`${signal} — shutting down`);
  await server.stop();
  process.exit(0);
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

try {
  await server.start();
} catch (e) {
  log(`failed to start: ${e.message}`);
  process.exit(1);
}
