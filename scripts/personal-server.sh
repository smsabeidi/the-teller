#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
umask 077

if [ "${1:-}" = "init" ]; then
    if [ -e .env ]; then
        printf '%s\n' 'An .env file already exists. Edit it to enable personal mode without replacing your settings.'
        exit 1
    fi
    python3 - <<'PY'
from pathlib import Path
import secrets

template = Path(".env.example").read_text()
settings = template.replace("TELLER_PERSONAL_MODE=0", "TELLER_PERSONAL_MODE=1")
settings = settings.replace("TELLER_ACCESS_KEY=\n", f"TELLER_ACCESS_KEY={secrets.token_urlsafe(40)}\n")
with Path(".env").open("x") as env:
    env.write(settings)
PY
    printf '%s\n' 'Created a private .env. Save its TELLER_ACCESS_KEY in your password manager.'
    exit 0
fi

if [ "${1:-}" != "start" ]; then
    printf '%s\n' 'Usage: scripts/personal-server.sh init|start'
    exit 2
fi

PYTHON_BINARY="${TELLER_PYTHON:-.venv/bin/python}"
if [ ! -x "$PYTHON_BINARY" ]; then
    printf '%s\n' 'Create .venv and install requirements.txt first (see README.md).'
    exit 1
fi
# Bind the internal server to loopback. A private HTTPS proxy supplies phone access.
export TELLER_PERSONAL_MODE=1
exec "$PYTHON_BINARY" -m uvicorn server:app --host 127.0.0.1 --port "${TELLER_PORT:-8016}" --no-access-log
