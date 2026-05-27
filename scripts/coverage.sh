#!/usr/bin/env bash
# Generate code coverage report using kcov.
# Requires: kcov (apt: kcov, or build from https://github.com/SimonKagstrom/kcov)
set -euo pipefail

if ! command -v kcov &>/dev/null; then
  echo "kcov not found. Install with:"
  echo "  sudo apt install kcov         # Debian/Ubuntu/Raspberry Pi OS"
  echo "  brew install kcov             # macOS"
  exit 1
fi

cd "$(dirname "$0")/.."

echo "Running tests with coverage..."
zig build test -Dcoverage=true -Doptimize=Debug

REPORT="zig-out/coverage/index.html"
if [ -f "$REPORT" ]; then
  echo ""
  echo "Coverage report: $REPORT"
  echo "Open in browser:  xdg-open $REPORT"
else
  echo "Coverage report not found at $REPORT"
  echo "Check zig-out/coverage/ for output."
fi
