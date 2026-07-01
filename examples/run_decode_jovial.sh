#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

INPUT_MP4="$SCRIPT_DIR/jovial.mp4"
OUTPUT_PNG="$SCRIPT_DIR/jovial_decoded.png"
BEST_PARAMS_FILE="$SCRIPT_DIR/jovial_best_params.env"

if [[ ! -f "$INPUT_MP4" ]]; then
  echo "Input MP4 not found: $INPUT_MP4" >&2
  echo "Run examples/run_encode_jovial.sh first." >&2
  exit 1
fi

if [[ -f "$BEST_PARAMS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$BEST_PARAMS_FILE"
  echo "Using tuned parameters from: $BEST_PARAMS_FILE"
fi

COLS="${COLS:-96}" \
ROWS="${ROWS:-54}" \
BITS_PER_CELL="${BITS_PER_CELL:-2}" \
"$REPO_ROOT/decode.sh" "$INPUT_MP4" "$OUTPUT_PNG" "$@"

echo "Created decoded PNG: $OUTPUT_PNG"
