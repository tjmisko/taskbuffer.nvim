#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../go"

echo "==> Building..."
go build -o task_bin .

echo "==> Running all tests..."
go test -v -count=1 ./...

echo ""
echo "==> All tests passed"
