#!/usr/bin/env bash
# Quick launcher for UA-MCU Bridge
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$DIR"

PORT="${1:-3}"

echo "Starting UA-MCU Bridge for SSL UF8 (Layer port: $PORT)..."
python3 bridge.py --port "$PORT"
