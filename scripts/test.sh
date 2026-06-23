#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Running Lua tests..."
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/"

echo ""
echo "==> All tests passed"
