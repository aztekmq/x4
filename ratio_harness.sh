#!/usr/bin/env bash
# Copyright (c) 2026 AztekMQ LLC (aztekmq.net) - Rob Lee
# All rights reserved.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  ./ratio_harness.sh --suite [REPORT_DIR]
  ./ratio_harness.sh INPUT [REPORT_DIR]

Modes:
  --suite
      Generate deterministic high-entropy binary inputs and benchmark each
      size class. Default size classes are: 1K 10K 100K 1M 10M 100M.

  INPUT
      Benchmark one existing input file.

Outputs:
  REPORT_DIR/evidence.log
  REPORT_DIR/trials.csv
  REPORT_DIR/summary.csv
  REPORT_DIR/report.html

Experimental controls:
  SIZE_CLASSES            Generated suite sizes. Default: 1K 10K 100K 1M 10M 100M
  DIMENSIONS              Space-separated COLSxROWS list.
  CELLS                   Space-separated cell sizes. Default: 12 10 8 6 5 4 3 2
  BITS                    Space-separated bits-per-cell list. Default: 2 4 1 8
  FPS_VALUES              Space-separated fps list. Default: 1
  REPEATS                 Space-separated repeat list. Default: 1
  TAIL_FRAMES             Tail frames appended by encoder. Default: 0
  MAX_TRIALS_PER_INPUT    Trial budget per input. Default: 80 for suite, 160 for single file
  ADAPTIVE                Use prior size results to warm-start larger files. Default: 1
  KEEP_BEST               Preserve best MP4 and decoded output per input. Default: 0
  KEEP_CORPUS             Preserve generated binary corpus. Default: 0

Examples:
  ./ratio_harness.sh --suite ratio_reports/binary_suite
  MAX_TRIALS_PER_INPUT=240 KEEP_BEST=1 ./ratio_harness.sh --suite ratio_reports/deep_suite
  ./ratio_harness.sh README.md ratio_reports/readme
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

timestamp="$(date '+%Y%m%d_%H%M%S')"
suite_mode=0
single_input=""

if [[ "${1:-}" == "--suite" ]]; then
  suite_mode=1
  report_dir="${2:-$SCRIPT_DIR/ratio_reports/binary_suite_$timestamp}"
elif [[ $# -ge 1 ]]; then
  single_input=$1
  if [[ ! -f "$single_input" ]]; then
    printf 'Input file not found: %s\n' "$single_input" >&2
    exit 1
  fi
  report_dir="${2:-$SCRIPT_DIR/ratio_reports/single_$timestamp}"
else
  usage
  exit 0
fi

work_dir="$report_dir/work"
corpus_dir="$work_dir/corpus"
log_file="$report_dir/evidence.log"
trial_csv="$report_dir/trials.csv"
summary_csv="$report_dir/summary.csv"
html_file="$report_dir/report.html"

size_classes="${SIZE_CLASSES:-1K 10K 100K 1M 10M 100M}"
dimensions="${DIMENSIONS:-12x10 16x10 20x16 24x14 32x10 32x20 48x27 64x36 96x54}"
cells="${CELLS:-12 10 8 6 5 4 3 2}"
bits_values="${BITS:-2 4 1 8}"
fps_values="${FPS_VALUES:-1}"
repeats="${REPEATS:-1}"
tail_frames="${TAIL_FRAMES:-0}"
keep_best="${KEEP_BEST:-0}"
keep_corpus="${KEEP_CORPUS:-0}"
adaptive="${ADAPTIVE:-1}"

if [[ -n "${MAX_TRIALS:-}" && -z "${MAX_TRIALS_PER_INPUT:-}" ]]; then
  max_trials_per_input="$MAX_TRIALS"
elif [[ -n "${MAX_TRIALS_PER_INPUT:-}" ]]; then
  max_trials_per_input="$MAX_TRIALS_PER_INPUT"
elif [[ "$suite_mode" == "1" ]]; then
  max_trials_per_input=80
else
  max_trials_per_input=160
fi

mkdir -p "$work_dir" "$corpus_dir"
rm -f "$work_dir"/trial_* "$report_dir"/best_*.mp4 "$report_dir"/best_*.decoded

html_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g'
}

bytes_for_size() {
  local size=$1 number suffix
  number="${size%[KkMmGg]}"
  suffix="${size#$number}"
  case "$suffix" in
    K|k) printf '%s\n' "$((number * 1024))" ;;
    M|m) printf '%s\n' "$((number * 1024 * 1024))" ;;
    G|g) printf '%s\n' "$((number * 1024 * 1024 * 1024))" ;;
    "") printf '%s\n' "$number" ;;
    *) printf 'Invalid size class: %s\n' "$size" >&2; return 1 ;;
  esac
}

ratio_of() {
  awk -v out="$1" -v in_size="$2" 'BEGIN { if (in_size == 0) print "0.000000"; else printf "%.6f", out / in_size }'
}

distance_from_one() {
  awk -v ratio="$1" 'BEGIN { d = ratio - 1; if (d < 0) d = -d; printf "%.6f", d }'
}

is_less() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'
}

abs_diff() {
  awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.6f", d }'
}

predict_ratio() {
  local current_size=$1
  if [[ "${#history_sizes[@]}" -ge 2 ]]; then
    local last_index prev_index
    last_index=$((${#history_sizes[@]} - 1))
    prev_index=$((${#history_sizes[@]} - 2))
    awk \
      -v s0="${history_sizes[$prev_index]}" \
      -v r0="${history_ratios[$prev_index]}" \
      -v s1="${history_sizes[$last_index]}" \
      -v r1="${history_ratios[$last_index]}" \
      -v sx="$current_size" \
      'BEGIN {
        if (s0 > 0 && s1 > 0 && sx > 0 && r0 > 0 && r1 > 0 && s0 != s1) {
          slope = log(r1 / r0) / log(s1 / s0);
          printf "%.6f", r1 * exp(slope * log(sx / s1));
        } else {
          printf "%.6f", r1;
        }
      }'
  elif [[ "${#history_ratios[@]}" -eq 1 ]]; then
    printf '%s' "${history_ratios[0]}"
  else
    printf ''
  fi
}

append_candidate() {
  local file=$1 strategy=$2 cols=$3 rows=$4 cell=$5 bits=$6 fps=$7 repeat=$8 key
  key="${cols},${rows},${cell},${bits},${fps},${repeat}"
  if ! cut -d, -f2- "$file" 2>/dev/null | grep -Fqx "$key"; then
    printf '%s,%s\n' "$strategy" "$key" >> "$file"
  fi
}

build_candidates() {
  local file=$1
  : > "$file"

  if [[ "$adaptive" == "1" && -n "${prev_cols:-}" ]]; then
    append_candidate "$file" "prior-exact" "$prev_cols" "$prev_rows" "$prev_cell" "$prev_bits" "$prev_fps" "$prev_repeat"

    for cell in $cells; do
      append_candidate "$file" "local-cell" "$prev_cols" "$prev_rows" "$cell" "$prev_bits" "$prev_fps" "$prev_repeat"
    done

    for bits in $bits_values; do
      append_candidate "$file" "local-bits" "$prev_cols" "$prev_rows" "$prev_cell" "$bits" "$prev_fps" "$prev_repeat"
    done

    for dim in $dimensions; do
      cols="${dim%x*}"
      rows="${dim#*x}"
      [[ -z "$cols" || -z "$rows" || "$cols" == "$dim" ]] && continue
      append_candidate "$file" "local-grid" "$cols" "$rows" "$prev_cell" "$prev_bits" "$prev_fps" "$prev_repeat"
    done
  fi

  for bits in $bits_values; do
    for dim in $dimensions; do
      cols="${dim%x*}"
      rows="${dim#*x}"
      [[ -z "$cols" || -z "$rows" || "$cols" == "$dim" ]] && continue
      for fps in $fps_values; do
        for repeat in $repeats; do
          for cell in $cells; do
            append_candidate "$file" "global-grid" "$cols" "$rows" "$cell" "$bits" "$fps" "$repeat"
          done
        done
      done
    done
  done
}

cleanup_trial() {
  rm -f "$work_dir"/trial_*.mp4 "$work_dir"/trial_*.decoded "$work_dir"/trial_*.encode.log "$work_dir"/trial_*.decode.log "$work_dir"/candidates_*.txt
}

cleanup_all() {
  cleanup_trial
  if [[ "$keep_corpus" != "1" ]]; then
    rm -rf "$work_dir"
  fi
}

trap cleanup_all EXIT

make_generated_input() {
  local label=$1 bytes=$2 output=$3 key iv
  key="00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
  iv="$(printf '%032x' "$bytes")"

  if command -v openssl >/dev/null 2>&1; then
    head -c "$bytes" /dev/zero | openssl enc -aes-256-ctr -K "$key" -iv "$iv" -nosalt > "$output.tmp"
    mv "$output.tmp" "$output"
  else
    printf 'openssl not found; falling back to non-deterministic /dev/urandom for %s\n' "$label" | tee -a "$log_file"
    dd if=/dev/urandom of="$output" bs=1M count=$((bytes / 1048576)) status=none 2>/dev/null
    dd if=/dev/urandom bs=1 count=$((bytes % 1048576)) status=none 2>/dev/null >> "$output"
  fi
}

write_report() {
  local completed_at best_global_ratio best_global_label best_global_input best_global_output best_global_params best_ratio_suffix summaries trials
  completed_at="$(date '+%Y-%m-%d %H:%M:%S %Z')"

  if [[ -s "$summary_csv" ]]; then
    best_global_ratio="$(
      awk -F, 'NR > 1 && $3 == "ok" && ($5 + 0) > 0 {
        if (!seen || ($5 + 0) < best) { seen=1; best=$5; label=$1; input=$2; output=$4; params=$10 }
      } END { if (seen) printf "%s,%s,%s,%s,%s", best, label, input, output, params; }' "$summary_csv"
    )"
  else
    best_global_ratio=""
  fi

  if [[ -n "$best_global_ratio" ]]; then
    IFS=, read -r best_ratio_value best_global_label best_global_input best_global_output best_global_params <<< "$best_global_ratio"
    best_ratio_suffix="x"
  else
    best_ratio_value="No match"
    best_ratio_suffix=""
    best_global_label="n/a"
    best_global_input="n/a"
    best_global_output="n/a"
    best_global_params="No successful encode/decode match was found."
  fi

  summaries="$(
    awk -F, 'NR > 1 {
      row_class = ($3 == "ok") ? "ok" : "fail";
      printf "<tr class=\"%s\"><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n",
        row_class, $1, $2, $3, $6, $5, $7, $4, $8, $9, $10
    }' "$summary_csv"
  )"

  trials="$(
    awk -F, 'NR > 1 {
      row_class = ($4 == "ok") ? "ok" : "fail";
      printf "<tr class=\"%s\"><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n",
        row_class, $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15
    }' "$trial_csv"
  )"

  cat > "$html_file" <<HTML
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Visual MIMO Binary Transfer Ratio Study</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #111827;
      --muted: #4b5563;
      --line: #d7dce5;
      --surface: #f8fafc;
      --surface-strong: #eef4fb;
      --accent: #174a7c;
      --ok: #0f6b3f;
      --fail: #9f2d2d;
    }
    body {
      margin: 0;
      font-family: "Segoe UI", Arial, Helvetica, sans-serif;
      color: var(--ink);
      background: #ffffff;
    }
    header {
      padding: 30px 42px 24px;
      border-bottom: 1px solid var(--line);
      background: var(--surface);
    }
    .brand {
      color: var(--accent);
      font-size: 13px;
      font-weight: 700;
      letter-spacing: 0;
      text-transform: uppercase;
    }
    h1 {
      margin: 8px 0 6px;
      font-size: 30px;
      letter-spacing: 0;
    }
    main {
      padding: 30px 42px 44px;
    }
    .finding {
      border: 2px solid var(--accent);
      border-radius: 8px;
      background: var(--surface-strong);
      padding: 24px;
      margin-bottom: 26px;
    }
    .finding-label {
      color: var(--accent);
      font-size: 13px;
      font-weight: 800;
      text-transform: uppercase;
    }
    .ratio {
      margin: 8px 0 18px;
      font-size: 62px;
      line-height: 1;
      font-weight: 850;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(230px, 1fr));
      gap: 14px;
    }
    .metric {
      background: #ffffff;
      border: 1px solid var(--line);
      border-radius: 6px;
      padding: 14px;
    }
    .metric span {
      display: block;
      color: var(--muted);
      font-size: 12px;
      margin-bottom: 6px;
    }
    .metric strong {
      font-size: 17px;
      overflow-wrap: anywhere;
    }
    h2 {
      margin: 28px 0 10px;
      font-size: 20px;
    }
    p {
      max-width: 980px;
      color: var(--muted);
      line-height: 1.55;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 13px;
    }
    th, td {
      border-bottom: 1px solid var(--line);
      padding: 8px 9px;
      text-align: left;
      white-space: nowrap;
    }
    th {
      background: var(--surface);
      color: #334155;
      position: sticky;
      top: 0;
    }
    tr.ok td:nth-child(3), tr.ok td:nth-child(4) {
      color: var(--ok);
      font-weight: 700;
    }
    tr.fail td:nth-child(3), tr.fail td:nth-child(4) {
      color: var(--fail);
      font-weight: 700;
    }
    .table-wrap {
      border: 1px solid var(--line);
      border-radius: 6px;
      overflow-x: auto;
      margin-top: 10px;
    }
    details {
      margin-top: 24px;
      color: var(--muted);
    }
    summary {
      cursor: pointer;
      color: var(--accent);
      font-weight: 700;
    }
    code {
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: 4px;
      padding: 1px 4px;
    }
  </style>
</head>
<body>
  <header>
    <div class="brand">aztekmq llc &bull; rob@aztekmq.net</div>
    <h1>Visual MIMO Binary Transfer Ratio Study</h1>
    <div>Generated ${completed_at}</div>
  </header>
  <main>
    <section class="finding">
      <div class="finding-label">Best verified output/input ratio across the corpus</div>
      <div class="ratio">$(printf '%s' "$best_ratio_value" | html_escape)${best_ratio_suffix}</div>
      <div class="grid">
        <div class="metric"><span>Corpus member</span><strong>$(printf '%s' "$best_global_label" | html_escape)</strong></div>
        <div class="metric"><span>Input size</span><strong>$(printf '%s' "$best_global_input" | html_escape) bytes</strong></div>
        <div class="metric"><span>MP4 output size</span><strong>$(printf '%s' "$best_global_output" | html_escape) bytes</strong></div>
        <div class="metric"><span>Winning parameters</span><strong>$(printf '%s' "$best_global_params" | html_escape)</strong></div>
      </div>
    </section>

    <h2>Abstract</h2>
    <p>This experiment measures the empirical compression envelope of the Visual MIMO MP4 transfer path. A result is admitted only when the encoded MP4 decodes to a byte-identical reconstruction of the input. The primary dependent variable is the MP4 output/input byte ratio; lower values are better, with 1.0 representing parity with the source file.</p>

    <h2>Method</h2>
    <p>The generated corpus uses deterministic high-entropy binary files to reduce accidental gains from source compression. Inputs are evaluated from smallest to largest. The first input performs broad exploration; each later input tests the prior winner first, probes local neighborhoods around that winner, and then falls back to the global grid when budget remains. Temporary MP4 and decoded artifacts are removed after measurement. The evidence log and CSV files preserve the complete trial record.</p>

    <h2>Validity Notes</h2>
    <p>The study reports empirical results for the local OpenCV MP4 encoder, installed codecs, CPU, and decoder implementation. The search is budgeted by <code>MAX_TRIALS_PER_INPUT</code>; therefore, the best ratio is the best verified result within the tested parameter space, not a mathematical lower bound. A failed trial is retained when encoding fails, decoding fails, or the decoded byte stream differs from the source.</p>

    <h2>Best Result by Input Size</h2>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Input</th><th>Input bytes</th><th>Status</th><th>Predicted ratio</th><th>Actual ratio</th><th>Error</th><th>MP4 bytes</th><th>Trial</th><th>Prediction</th><th>Winner</th>
          </tr>
        </thead>
        <tbody>
${summaries}
        </tbody>
      </table>
    </div>

    <details>
      <summary>Experimental controls</summary>
      <p><code>SIZE_CLASSES=$(printf '%s' "$size_classes" | html_escape)</code></p>
      <p><code>DIMENSIONS=$(printf '%s' "$dimensions" | html_escape)</code></p>
      <p><code>CELLS=$(printf '%s' "$cells" | html_escape)</code></p>
      <p><code>BITS=$(printf '%s' "$bits_values" | html_escape)</code></p>
      <p><code>FPS_VALUES=$(printf '%s' "$fps_values" | html_escape)</code>, <code>REPEATS=$(printf '%s' "$repeats" | html_escape)</code>, <code>TAIL_FRAMES=$(printf '%s' "$tail_frames" | html_escape)</code>, <code>MAX_TRIALS_PER_INPUT=$(printf '%s' "$max_trials_per_input" | html_escape)</code>, <code>ADAPTIVE=$(printf '%s' "$adaptive" | html_escape)</code></p>
    </details>

    <h2>Complete Trial Evidence</h2>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Input</th><th>Trial</th><th>Strategy</th><th>Status</th><th>Ratio</th><th>MP4 bytes</th><th>Cols</th><th>Rows</th><th>Cell</th><th>Bits</th><th>FPS</th><th>Repeat</th><th>Tail</th><th>Reason</th><th>Input bytes</th>
          </tr>
        </thead>
        <tbody>
${trials}
        </tbody>
      </table>
    </div>
  </main>
</body>
</html>
HTML
}

{
  printf 'Visual MIMO binary transfer ratio study\n'
  printf 'Started: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf 'Mode: %s\n' "$([[ "$suite_mode" == "1" ]] && printf 'generated-suite' || printf 'single-input')"
  printf 'Report dir: %s\n' "$report_dir"
  printf 'Size classes: %s\n' "$size_classes"
  printf 'Dimensions: %s\n' "$dimensions"
  printf 'Cells: %s\n' "$cells"
  printf 'Bits: %s\n' "$bits_values"
  printf 'FPS values: %s\n' "$fps_values"
  printf 'Repeats: %s\n' "$repeats"
  printf 'Tail frames: %s\n' "$tail_frames"
  printf 'Adaptive search: %s\n' "$adaptive"
  printf 'Max trials per input: %s\n\n' "$max_trials_per_input"
} > "$log_file"

printf 'input_label,trial,strategy,status,ratio,mp4_bytes,cols,rows,cell,bits,fps,repeat,tail,reason,input_bytes\n' > "$trial_csv"
printf 'input_label,input_bytes,status,mp4_bytes,actual_ratio,predicted_ratio,prediction_error,trial,predicted_parameters,winning_parameters,sha256\n' > "$summary_csv"

input_paths=()
input_labels=()
history_sizes=()
history_ratios=()
prev_cols=""
prev_rows=""
prev_cell=""
prev_bits=""
prev_fps=""
prev_repeat=""
prev_params=""

if [[ "$suite_mode" == "1" ]]; then
  size_manifest="$work_dir/size_manifest.txt"
  : > "$size_manifest"
  for size_label in $size_classes; do
    bytes="$(bytes_for_size "$size_label")"
    printf '%s %s\n' "$bytes" "$size_label" >> "$size_manifest"
  done

  while read -r bytes size_label; do
    path="$corpus_dir/binary_${size_label}.bin"
    printf 'Generating corpus member %s (%s bytes)\n' "$size_label" "$bytes" | tee -a "$log_file"
    make_generated_input "$size_label" "$bytes" "$path"
    input_paths+=("$path")
    input_labels+=("$size_label")
  done < <(sort -n "$size_manifest")
else
  input_paths+=("$(cd -- "$(dirname -- "$single_input")" && pwd)/$(basename -- "$single_input")")
  input_labels+=("$(basename -- "$single_input")")
fi

for input_index in "${!input_paths[@]}"; do
  input_abs="${input_paths[$input_index]}"
  input_label="${input_labels[$input_index]}"
  input_size="$(stat -c '%s' "$input_abs")"
  sha256="$(sha256sum "$input_abs" | awk '{print $1}')"

  trial_count=0
  success_count=0
  failure_count=0
  best_distance=""
  best_ratio=""
  best_size=""
  best_trial=""
  best_params=""
  best_cols=""
  best_rows=""
  best_cell=""
  best_bits=""
  best_fps=""
  best_repeat=""
  predicted_ratio="$(predict_ratio "$input_size")"
  predicted_params="${prev_params:-none}"
  safe_label="${input_label//[^A-Za-z0-9_.-]/_}"
  candidate_file="$work_dir/candidates_${safe_label}.txt"

  {
    printf '\n=== Input: %s ===\n' "$input_label"
    printf 'Path: %s\n' "$input_abs"
    printf 'Input bytes: %s\n' "$input_size"
    printf 'SHA-256: %s\n' "$sha256"
    printf 'Predicted ratio: %s\n' "${predicted_ratio:-none}"
    printf 'Predicted parameters: %s\n' "$predicted_params"
  } | tee -a "$log_file"

  build_candidates "$candidate_file"

  while IFS=, read -r strategy cols rows cell bits fps repeat; do
    if (( trial_count >= max_trials_per_input )); then
      printf 'Reached MAX_TRIALS_PER_INPUT=%s for %s\n' "$max_trials_per_input" "$input_label" | tee -a "$log_file"
      break
    fi

    trial_count=$((trial_count + 1))
    mp4="$work_dir/trial_${safe_label}_${trial_count}.mp4"
    decoded="$work_dir/trial_${safe_label}_${trial_count}.decoded"
    enc_log="$work_dir/trial_${safe_label}_${trial_count}.encode.log"
    dec_log="$work_dir/trial_${safe_label}_${trial_count}.decode.log"
    status="fail"
    ratio=""
    mp4_bytes=""
    reason=""

    printf 'Trial %s/%03d [%s]: cols=%s rows=%s cell=%s bits=%s fps=%s repeat=%s tail=%s\n' \
      "$input_label" "$trial_count" "$strategy" "$cols" "$rows" "$cell" "$bits" "$fps" "$repeat" "$tail_frames" | tee -a "$log_file"

    if FPS="$fps" COLS="$cols" ROWS="$rows" CELL="$cell" BITS_PER_CELL="$bits" REPEAT="$repeat" TAIL_FRAMES="$tail_frames" \
        "$SCRIPT_DIR/encode.sh" "$input_abs" "$mp4" > "$enc_log" 2>&1; then
      mp4_bytes="$(stat -c '%s' "$mp4")"
      ratio="$(ratio_of "$mp4_bytes" "$input_size")"

      if COLS="$cols" ROWS="$rows" BITS_PER_CELL="$bits" "$SCRIPT_DIR/decode.sh" "$mp4" "$decoded" > "$dec_log" 2>&1; then
        if cmp -s "$input_abs" "$decoded"; then
          status="ok"
          reason="match"
          success_count=$((success_count + 1))
          distance="$(distance_from_one "$ratio")"
          params="cols=${cols}; rows=${rows}; cell=${cell}; bits=${bits}; fps=${fps}; repeat=${repeat}; tail=${tail_frames}"
          if [[ -z "$best_distance" ]] || is_less "$distance" "$best_distance"; then
            best_distance="$distance"
            best_ratio="$ratio"
            best_size="$mp4_bytes"
            best_trial="$trial_count"
            best_params="$params"
            best_cols="$cols"
            best_rows="$rows"
            best_cell="$cell"
            best_bits="$bits"
            best_fps="$fps"
            best_repeat="$repeat"
            if [[ "$keep_best" == "1" ]]; then
              cp "$mp4" "$report_dir/best_${safe_label}.mp4"
              cp "$decoded" "$report_dir/best_${safe_label}.decoded"
            fi
          fi
        else
          reason="decoded_mismatch"
          failure_count=$((failure_count + 1))
        fi
      else
        reason="decode_failed"
        failure_count=$((failure_count + 1))
      fi
    else
      reason="encode_failed"
      failure_count=$((failure_count + 1))
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$input_label" "$trial_count" "$strategy" "$status" "${ratio:-}" "${mp4_bytes:-}" "$cols" "$rows" "$cell" "$bits" "$fps" "$repeat" "$tail_frames" "$reason" "$input_size" >> "$trial_csv"

    printf '  -> %s ratio=%s bytes=%s reason=%s\n' "$status" "${ratio:-n/a}" "${mp4_bytes:-n/a}" "$reason" | tee -a "$log_file"

    cleanup_trial
  done < "$candidate_file"

  if [[ -n "$best_ratio" ]]; then
    prediction_error=""
    if [[ -n "$predicted_ratio" ]]; then
      prediction_error="$(abs_diff "$best_ratio" "$predicted_ratio")"
    fi
    printf '%s,%s,ok,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$input_label" "$input_size" "$best_size" "$best_ratio" "${predicted_ratio:-}" "$prediction_error" "$best_trial" "$predicted_params" "$best_params" "$sha256" >> "$summary_csv"
    printf 'Best for %s: ratio=%s mp4_bytes=%s trial=%s params=%s\n' "$input_label" "$best_ratio" "$best_size" "$best_trial" "$best_params" | tee -a "$log_file"
    history_sizes+=("$input_size")
    history_ratios+=("$best_ratio")
    prev_cols="$best_cols"
    prev_rows="$best_rows"
    prev_cell="$best_cell"
    prev_bits="$best_bits"
    prev_fps="$best_fps"
    prev_repeat="$best_repeat"
    prev_params="$best_params"
  else
    printf '%s,%s,fail,,,%s,,,,%s,%s\n' "$input_label" "$input_size" "${predicted_ratio:-}" "$predicted_params" "$sha256" >> "$summary_csv"
    printf 'No successful decode for %s after %s trials.\n' "$input_label" "$trial_count" | tee -a "$log_file"
  fi

  printf 'Completed %s: trials=%s successes=%s failures=%s\n' "$input_label" "$trial_count" "$success_count" "$failure_count" | tee -a "$log_file"
done

write_report
printf '\nCompleted: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" >> "$log_file"
printf 'Report: %s\nEvidence log: %s\nTrials CSV: %s\nSummary CSV: %s\n' "$html_file" "$log_file" "$trial_csv" "$summary_csv"
