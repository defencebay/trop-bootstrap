#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$REPO_ROOT/trop-bootstrap.sh"
test "$("$REPO_ROOT/trop-bootstrap.sh" --version)" = "0.1.0"
"$REPO_ROOT/trop-bootstrap.sh" --help | grep -q -- '--fetch-only'

echo "Bootstrap smoke test passed"
