#!/usr/bin/env bash
# Copyright (c) 2026 AztekMQ LLC (aztekmq.net) - Rob Lee
# All rights reserved.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  ./decode.sh VIDEO [OUTPUT] [visual_mimo decode-video options]
  ./decode.sh --camera [OUTPUT] [visual_mimo decode-camera options]

Defaults can be overridden with environment variables:
  COLS=96 ROWS=54 BITS_PER_CELL=2 CAMERA=0

Examples:
  ./decode.sh transfer.mp4 recovered.bin
  COLS=64 ROWS=36 ./decode.sh transfer.mp4 recovered.txt
  ./decode.sh --camera recovered.bin --camera 1
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 ]]; then
  usage
  exit 0
fi

python_bin="${PYTHON:-}"
if [[ -z "$python_bin" ]]; then
  if [[ -x "$SCRIPT_DIR/.venv/bin/python" ]]; then
    python_bin="$SCRIPT_DIR/.venv/bin/python"
  else
    python_bin="python3"
  fi
fi

if [[ "${1:-}" == "--camera" ]]; then
  shift
  output=${1:-recovered.bin}
  if [[ $# -gt 0 ]]; then
    shift
  fi

  exec "$python_bin" "$SCRIPT_DIR/visual_mimo.py" decode-camera "$output" \
    --camera "${CAMERA:-0}" \
    --cols "${COLS:-96}" \
    --rows "${ROWS:-54}" \
    --bits-per-cell "${BITS_PER_CELL:-2}" \
    "$@"
fi

input=$1
output=${2:-recovered.bin}
shift
if [[ $# -gt 0 ]]; then
  shift
fi

exec "$python_bin" "$SCRIPT_DIR/visual_mimo.py" decode-video "$input" "$output" \
  --cols "${COLS:-96}" \
  --rows "${ROWS:-54}" \
  --bits-per-cell "${BITS_PER_CELL:-2}" \
  "$@"
