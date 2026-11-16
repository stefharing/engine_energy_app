#!/usr/bin/env bash
# Start de debug-webapp op http://127.0.0.1:8000 (maakt zo nodig een venv).
set -euo pipefail
cd "$(dirname "$0")"
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q -r requirements.txt
exec .venv/bin/uvicorn app:app --reload --host 127.0.0.1 --port 8000
