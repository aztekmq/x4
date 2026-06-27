#!/usr/bin/env bash
# Copyright (c) 2026 AztekMQ LLC (aztekmq.net) - Rob Lee
# All rights reserved.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  ./encode.sh INPUT [OUTPUT] [visual_mimo encode options]

Defaults can be overridden with environment variables:
  FPS=30 COLS=96 ROWS=54 CELL=10 BITS_PER_CELL=2 REPEAT=3 TAIL_FRAMES=0 ZSTD_LEVEL=3

Example:
  ./encode.sh input.bin transfer.mp4
  COLS=64 ROWS=36 CELL=12 ./encode.sh input.bin transfer.mp4
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 ]]; then
  usage
  exit 0
fi

input=$1
output=${2:-transfer.mp4}
shift
if [[ $# -gt 0 ]]; then
  shift
fi

python_bin="${PYTHON:-}"
if [[ -z "$python_bin" ]]; then
  if [[ -x "$SCRIPT_DIR/.venv/bin/python" ]]; then
    python_bin="$SCRIPT_DIR/.venv/bin/python"
  else
    python_bin="python3"
  fi
fi

exec "$python_bin" "$SCRIPT_DIR/visual_mimo.py" encode "$input" "$output" \
  --fps "${FPS:-30}" \
  --cols "${COLS:-96}" \
  --rows "${ROWS:-54}" \
  --cell "${CELL:-10}" \
  --bits-per-cell "${BITS_PER_CELL:-2}" \
  --repeat "${REPEAT:-3}" \
  --tail-frames "${TAIL_FRAMES:-0}" \
  --zstd-level "${ZSTD_LEVEL:-3}" \
  "$@"
