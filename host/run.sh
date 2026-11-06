#!/usr/bin/env bash
# babel-host launcher (systemd ExecStart)
set -euo pipefail
cd "$(dirname "$0")"
exec node src/index.mjs
