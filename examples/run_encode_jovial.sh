#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

INPUT_PNG="$REPO_ROOT/images/jovial.png"
OUTPUT_MP4="$SCRIPT_DIR/jovial.mp4"
BEST_PARAMS_FILE="$SCRIPT_DIR/jovial_best_params.env"

if [[ ! -f "$INPUT_PNG" ]]; then
  echo "Input image not found: $INPUT_PNG" >&2
  exit 1
fi

if [[ -f "$BEST_PARAMS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$BEST_PARAMS_FILE"
  echo "Using tuned parameters from: $BEST_PARAMS_FILE"
fi

FPS="${FPS:-30}" \
COLS="${COLS:-96}" \
ROWS="${ROWS:-54}" \
CELL="${CELL:-10}" \
BITS_PER_CELL="${BITS_PER_CELL:-2}" \
REPEAT="${REPEAT:-3}" \
TAIL_FRAMES="${TAIL_FRAMES:-0}" \
"$REPO_ROOT/encode.sh" "$INPUT_PNG" "$OUTPUT_MP4" "$@"

echo "Created MP4: $OUTPUT_MP4"
