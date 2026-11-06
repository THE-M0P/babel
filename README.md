# babel

Watch and steer remote coding sessions from your phone.

**babel** is an Android app + a tiny Node host that lets you follow a
[pi](https://pi.dev) coding agent running on your laptop in real time —
thinking, tool calls, results, streaming — and steer it: send prompts
mid-run, abort, rename, delete, and tap to approve when an extension
needs your input. Runs finish with a notification on your phone; tapping
it drops you back into the session.

The name is from the Babel Fish in *The Hitchhiker's Guide to the
Galaxy*: the agent is doing the computing, babel makes its output
comprehensible.

```
Phone (Android)                      Laptop
┌──────────────────┐   Tailscale    ┌─────────────────────────────┐
│ babel app (APK)  │◄──────────────►│ babel-host (Node, :8790)    │
│ · live transcript│  WebSocket +   │ · owns one pi process per   │
│ · prompt / steer │  static token  │   session (stdin/stdout)    │
│ · abort / rename │                │ · projects pi RPC JSONL →   │
│ · notifications  │                │   the JSON contract (doc 02)│
└──────────────────┘                └──────────────┬──────────────┘
                                                   │ pi --mode rpc
                                           ┌───────▼────────┐
                                           │ pi (pi.dev)    │
                                           └───────┬────────┘
                                                   │ OpenAI-compatible HTTP
                                           ┌───────▼────────┐
                                           │ your LLM       │  llama.cpp, ollama,
                                           └────────────────┘  OpenAI, …
```

Everything stays on your hardware: the host binds to your Tailscale
interface, sessions are plain JSONL files on the laptop, and the LLM key
never leaves pi. There is no cloud.

## Repository layout

| Path | What it is |
|---|---|
| `host/` | The session host (Node 20+, ESM, one dependency: `ws`). |
| `app/` | The Flutter (Android) app. |

The wire protocol is a small JSON contract over WebSocket; the frame
shapes are defined by `host/src/project.mjs` (projection) and
`app/lib/contract.dart` (parsing) — read those two files and the tests
next to them.

## Dependencies

### Laptop (the session host side)

| Dependency | Why | Install |
|---|---|---|
| **Node.js 20+** | Runs the host | `nvm install 22` or your distro's package |
| **[pi](https://pi.dev)** | The coding agent the host drives (`--mode rpc`) | `npm i -g @mariozechner/pi-coding-agent` |
| **Tailscale** | Private network between phone and laptop (no port forwarding) | `curl -fsSL https://tailscale.com/install.sh \| sh` |
| **An LLM** | What pi talks to — anything pi supports (llama.cpp, ollama, OpenAI, Anthropic, …) | already yours; pi is configured via its own settings |
| Linux/macOS | The host is a plain Node process; the systemd unit is Linux | — |

Any pi build with `--mode rpc` works. Forks with extra features
(session auto-titling, session file locking) work too — just point
`pi_bin` at the binary; babel doesn't care which one it is.

### Phone (the app side)

| Dependency | Why |
|---|---|
| Android 8+ | The app is an APK (no Play Store) |
| Tailscale (or any route to the laptop) | Reaching `host:8790` |
| Flutter 3.22+ | Only if you build the APK yourself |

## Quickstart

### 1. Laptop: install and run the host

```bash
# prerequisites
npm i -g @mariozechner/pi-coding-agent   # the agent
# (tailscale already installed and up: `tailscale up`)

git clone <this-repo> babel
cd babel/host
npm install

# config — the host reads ~/.config/babel/config.json
mkdir -p ~/.config/babel
cp config.example.json ~/.config/babel/config.json
# edit it:
#   "bind"      → your tailnet IP (`tailscale ip -4`)
#   "pi_bin"    → your pi binary (default: "pi")
#   "notify"    → optional: {url, key} of any /notify endpoint
#                 (e.g. your assistant) for out-of-app pings; null = off

# run it
node src/index.mjs
# first start generates the auth token at ~/.config/babel/token
```

The host listens on `ws://<bind>:8790/ws`. To run it as a service, see
`host/systemd/babel-host.service` (adjust the `ExecStart` path to your
clone location, then `systemctl --user daemon-reload && systemctl --user
enable --now babel-host`).

### 2. Phone: install the app and connect

Build the APK (one-time):

```bash
cd app
flutter pub get
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk
adb install build/app/outputs/flutter-apk/app-release.apk
```

Then in the app: **Settings → Host** = `<your-tailnet-ip>:8790`,
**Token** = the contents of `~/.config/babel/token` on the laptop →
Save. The status bar goes green when connected.

### 3. Use it

- **New session** (FAB): pick a working directory on the laptop, optional
  name, optional first prompt. The host spawns `pi --mode rpc` for it.
- **Session view**: live transcript — thinking (collapsible), assistant
  text (markdown), tool cards with args + results (tap to expand),
  per-message timestamps.
- **Composer**: send a prompt (idle → new run; mid-run → steer).
- **Stop** (app bar): abort the current run.
- **Long-press a session** in the list: rename or delete.
- **Needs input**: when an extension blocks on a confirmation, an
  Approve/Deny card appears (and a notification fires if the app is
  backgrounded).
- **Run finished**: local notification; tap → back in the session.

## Configuration reference

Host config (`~/.config/babel/config.json`; every key optional):

| Key | Default | Meaning |
|---|---|---|
| `port` | `8790` | WebSocket port |
| `bind` | `127.0.0.1` | Interface to bind — set your tailnet IP for phone access |
| `pi_bin` | `pi` | pi binary (any build with `--mode rpc`) |
| `session_dir` | `~/.local/share/babel/sessions` | Where host-spawned session files live (`~` expands) |
| `max_sessions` | `4` | Concurrent live pi processes |
| `tool_result_max_chars` | `4000` | Tool-result truncation in frames |
| `notify` | `null` | `{url, key}` for a `/notify` endpoint (out-of-app pings) |

The auth token is auto-generated at `~/.config/babel/token` (0600) on
first start. Stored sessions are discovered from pi's own session
directory (`~/.deepthought/agent/sessions/` for the deepthought fork,
`~/.pi/agent/sessions/` for upstream — the host scans both layouts) plus
`session_dir`.

## Security model (short version)

- **Network**: the host binds to your tailnet interface; only tailnet
  nodes can reach it. No public ports, no CGNAT tricks.
- **Auth**: a static 256-bit token in the WebSocket URL; wrong token →
  close `4401`.
- **Data**: sessions are local JSONL files. The only outbound calls are
  pi → your LLM, and optionally host → your `/notify` endpoint.

## Development

```bash
# host (Node 20+, node:test)
cd host && npm install && npm test
# integration tests need a real pi binary on PATH (or BABEL_TEST_PI_BIN);
# they skip cleanly without one.

# app (Flutter 3.22+)
cd app && flutter pub get && flutter test
```

The contract between host and app is versioned (`v` field): additive
changes don't bump the version; breaking ones do, and the app refuses
to talk to a host with a higher major version.

## License

MIT — see [LICENSE](LICENSE).
