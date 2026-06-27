# Visual MIMO Air-Gap Transfer

<p align="center">
  <img src="images/jovial.png" alt="Visual MIMO project artwork" width="520">
</p>

<p align="center">
  <img alt="Project status" src="https://img.shields.io/badge/status-experimental-174A7C">
  <img alt="Python" src="https://img.shields.io/badge/python-3.x-3776AB?logo=python&logoColor=white">
  <img alt="Bash" src="https://img.shields.io/badge/bash-harness-4EAA25?logo=gnubash&logoColor=white">
  <img alt="OpenCV" src="https://img.shields.io/badge/opencv-video%20processing-5C3EE8?logo=opencv&logoColor=white">
  <img alt="NumPy" src="https://img.shields.io/badge/numpy-vectorization-013243?logo=numpy&logoColor=white">
  <img alt="Zstandard" src="https://img.shields.io/badge/zstandard-compression-2F6F8F">
  <img alt="CRC32" src="https://img.shields.io/badge/crc32-packet%20validation-0F6B3F">
  <img alt="Air gap" src="https://img.shields.io/badge/air--gap-visual%20transfer-6B4F9B">
  <img alt="MP4" src="https://img.shields.io/badge/mp4-transport-455A64">
  <img alt="Adaptive benchmarking" src="https://img.shields.io/badge/adaptive-benchmarking-8A5A00">
</p>

Visual MIMO Air-Gap Transfer is an experimental file-transfer system that encodes binary data into video frames. The sender compresses and packetizes a source file, renders each packet as a visual grid, and writes the result to MP4. The receiver samples the video frames, validates packet CRC values, reconstructs the compressed stream, and writes a byte-identical recovered file when decoding succeeds.

This repository also includes an adaptive research harness for measuring how close the MP4 representation can get to the original file size while still decoding correctly.

## Contents

| Path | Description |
| --- | --- |
| `visual_mimo.py` | Core Python command-line application for encoding, playback, MP4 decoding, and camera decoding. |
| `encode.sh` | Bash wrapper for `visual_mimo.py encode`. Uses environment-variable defaults and passes through additional encoder options. |
| `decode.sh` | Bash wrapper for `decode-video` and `decode-camera`. |
| `ratio_harness.sh` | Adaptive experimental harness for size-ratio analysis across generated binary inputs or a single file. |
| `requirements.txt` | Python package dependencies. |
| `recovered.txt` | Example recovered output. |
| `ratio_reports/` | Generated evidence logs, CSV files, and HTML reports. |

## Architecture

The transfer path consists of four stages.

| Stage | Component | Description |
| --- | --- | --- |
| Input preparation | `visual_mimo.py encode` | Reads the source file and compresses it with `zstandard` when available, or `zlib` as a fallback. |
| Packetization | `visual_mimo.py encode` | Splits the compressed byte stream into packets. Each packet includes metadata and CRC32 validation. |
| Visual encoding | `visual_mimo.py encode` | Converts packet bytes into grayscale symbols arranged in a fixed cell grid and writes MP4 frames. |
| Recovery | `visual_mimo.py decode-video` or `decode-camera` | Samples symbols from frames, validates packets, reassembles the stream, decompresses it, and writes the recovered file. |

The visual format is controlled by grid dimensions, cell size, bits per cell, frame rate, repeated frames, and tail frames. These parameters trade off density, decode reliability, and MP4 output size.

## Requirements

- Bash
- Python 3
- OpenCV-compatible MP4 codec support
- Python packages listed in `requirements.txt`

Install dependencies:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

The wrapper scripts use `.venv/bin/python` automatically when it exists. Set `PYTHON=/path/to/python` to override interpreter selection.

## Quick Start

Encode a file:

```bash
printf 'hello air gap\n' > sample_input.txt
./encode.sh sample_input.txt transfer.mp4
```

Decode the MP4:

```bash
./decode.sh transfer.mp4 recovered.txt
```

Verify byte-identical recovery:

```bash
cmp sample_input.txt recovered.txt
```

`cmp` exits without output when the files match.

## Core Commands

Encode directly with Python:

```bash
python visual_mimo.py encode input.bin transfer.mp4 --fps 30 --cols 96 --rows 54 --cell 10 --bits-per-cell 2
```

Play an encoded MP4 full screen:

```bash
python visual_mimo.py play transfer.mp4
```

Decode an MP4 file:

```bash
python visual_mimo.py decode-video transfer.mp4 recovered.bin --cols 96 --rows 54 --bits-per-cell 2
```

Decode from a live camera:

```bash
python visual_mimo.py decode-camera recovered.bin --camera 0 --cols 96 --rows 54 --bits-per-cell 2
```

The decoder must use the same `--cols`, `--rows`, and `--bits-per-cell` values used by the encoder.

## Wrapper Reference

### `encode.sh`

```bash
./encode.sh INPUT [OUTPUT] [visual_mimo encode options]
```

| Variable | Default | Description |
| --- | ---: | --- |
| `FPS` | `30` | Output video frame rate. |
| `COLS` | `96` | Data grid columns. |
| `ROWS` | `54` | Data grid rows. |
| `CELL` | `10` | Pixel size of each grid cell. |
| `BITS_PER_CELL` | `2` | Bits encoded per cell. Valid values are `1`, `2`, `4`, and `8`. |
| `REPEAT` | `3` | Repetition count for each packet frame. |
| `TAIL_FRAMES` | `0` | White frames appended after packet frames. |
| `ZSTD_LEVEL` | `3` | Zstandard compression level when `zstandard` is available. |

Compact file-to-file example:

```bash
FPS=1 COLS=64 ROWS=36 CELL=8 BITS_PER_CELL=4 REPEAT=1 TAIL_FRAMES=0 ./encode.sh input.bin transfer.mp4
```

Reliability-oriented camera example:

```bash
FPS=30 COLS=64 ROWS=36 CELL=12 BITS_PER_CELL=2 REPEAT=3 TAIL_FRAMES=30 ./encode.sh input.bin transfer.mp4
```

### `decode.sh`

Decode from MP4:

```bash
./decode.sh VIDEO [OUTPUT] [visual_mimo decode-video options]
```

Decode from camera:

```bash
./decode.sh --camera [OUTPUT] [visual_mimo decode-camera options]
```

| Variable | Default | Description |
| --- | ---: | --- |
| `COLS` | `96` | Data grid columns used by the encoder. |
| `ROWS` | `54` | Data grid rows used by the encoder. |
| `BITS_PER_CELL` | `2` | Bits per cell used by the encoder. |
| `CAMERA` | `0` | Camera index for live decoding. |

Example:

```bash
COLS=64 ROWS=36 BITS_PER_CELL=4 ./decode.sh transfer.mp4 recovered.bin
```

## Adaptive Ratio Harness

`ratio_harness.sh` measures the MP4 output/input size ratio for settings that still decode to an exact byte match.

The harness supports two modes:

| Mode | Command | Purpose |
| --- | --- | --- |
| Generated suite | `./ratio_harness.sh --suite [REPORT_DIR]` | Generates deterministic binary files and analyzes each size class from smallest to largest. |
| Single input | `./ratio_harness.sh INPUT [REPORT_DIR]` | Analyzes one existing file. |

Generated suite defaults:

```text
1K 10K 100K 1M 10M 100M
```

Run the adaptive suite:

```bash
./ratio_harness.sh --suite ratio_reports/adaptive_binary_suite
```

Run a deeper adaptive suite:

```bash
MAX_TRIALS_PER_INPUT=240 KEEP_BEST=1 ./ratio_harness.sh --suite ratio_reports/adaptive_deep_suite
```

Run a single-file study:

```bash
./ratio_harness.sh README.md ratio_reports/readme_study
```

## Adaptive Search Method

The harness is sequential. It does not run the same blind parameter grid for every file size.

1. Inputs are ordered from smallest to largest.
2. The smallest input performs broad exploration.
3. The best successful parameters become the prediction for the next input size.
4. The next input tests the prior winner first.
5. The harness probes local neighborhoods around the prior winner:
   - same settings exactly: `prior-exact`
   - nearby cell sizes: `local-cell`
   - alternate bits-per-cell values: `local-bits`
   - alternate grid dimensions: `local-grid`
6. If budget remains, the harness falls back to `global-grid`.
7. Each successful result updates the prediction for the next larger file.

Prediction behavior:

| Available history | Prediction method |
| --- | --- |
| No prior result | No ratio prediction. Broad search only. |
| One prior result | Uses the prior best ratio and prior best parameters. |
| Two or more prior results | Uses log-log extrapolation over file size and best ratio. |

The harness records both predicted and actual results so the report can show prediction error by size.

## Harness Outputs

Each run writes the following files to the report directory.

| File | Description |
| --- | --- |
| `report.html` | Human-readable study report with best corpus result, per-size results, prediction error, and trial evidence. |
| `summary.csv` | One row per input size with predicted ratio, actual ratio, error, winning parameters, and SHA-256. |
| `trials.csv` | One row per attempted parameter set, including strategy, status, ratio, MP4 bytes, and reason. |
| `evidence.log` | Chronological execution log. |
| `best_<input>.mp4` | Optional best MP4 for each input when `KEEP_BEST=1`. |
| `best_<input>.decoded` | Optional decoded output for each input when `KEEP_BEST=1`. |

Temporary trial MP4 files, decoded files, encode logs, decode logs, and generated corpus files are removed automatically. Set `KEEP_CORPUS=1` to retain generated inputs.

## Harness Controls

| Variable | Default | Description |
| --- | --- | --- |
| `SIZE_CLASSES` | `1K 10K 100K 1M 10M 100M` | Generated suite sizes. Values are sorted numerically before analysis. |
| `DIMENSIONS` | `12x10 16x10 20x16 24x14 32x10 32x20 48x27 64x36 96x54` | Candidate grid dimensions. |
| `CELLS` | `12 10 8 6 5 4 3 2` | Candidate cell sizes. |
| `BITS` | `2 4 1 8` | Candidate bits-per-cell values. |
| `FPS_VALUES` | `1` | Candidate video frame rates. |
| `REPEATS` | `1` | Candidate packet-frame repeat counts. |
| `TAIL_FRAMES` | `0` | Tail frames appended to encoded videos during harness trials. |
| `MAX_TRIALS_PER_INPUT` | `80` in suite mode, `160` in single-file mode | Trial budget per input. |
| `ADAPTIVE` | `1` | Enables prior-result warm start and local search. Set to `0` for global-grid ordering only. |
| `KEEP_BEST` | `0` | Set to `1` to preserve best MP4 and decoded output per input. |
| `KEEP_CORPUS` | `0` | Set to `1` to preserve generated binary corpus files. |

Quick suite:

```bash
MAX_TRIALS_PER_INPUT=40 ./ratio_harness.sh --suite ratio_reports/quick_suite
```

Custom small suite:

```bash
SIZE_CLASSES="1K 10K 100K" \
DIMENSIONS="16x10 32x10 64x36" \
CELLS="8 4 2" \
BITS="2 4" \
MAX_TRIALS_PER_INPUT=24 \
./ratio_harness.sh --suite ratio_reports/small_suite
```

## Parameter Tuning Guidance

| Parameter | Smaller MP4 tendency | Higher decode reliability tendency |
| --- | --- | --- |
| `FPS` | Lower values, usually `1` for file-to-file studies. | Higher values for playback and camera capture. |
| `CELL` | Smaller cells reduce frame dimensions. | Larger cells tolerate video compression and camera blur better. |
| `BITS_PER_CELL` | Higher density can reduce packet count. | Lower density is easier to decode reliably. |
| `REPEAT` | `1` avoids redundant frames. | Higher values provide frame redundancy. |
| `TAIL_FRAMES` | `0` avoids non-payload frames. | Extra frames help live capture workflows. |
| `COLS` and `ROWS` | Smaller grids reduce frame dimensions. | Larger grids increase payload capacity and reduce packet count. |

For MP4 file-to-file experiments, start with:

```bash
FPS=1 REPEAT=1 TAIL_FRAMES=0
```

For camera experiments, start with:

```bash
FPS=30 REPEAT=3 TAIL_FRAMES=30 BITS_PER_CELL=2 CELL=12
```

## Throughput Estimate

Raw data capacity per frame is approximately:

```text
(cols * rows * bits_per_cell / 8) - packet_header
```

Example:

```text
96 * 54 * 2 / 8 = 1296 raw bytes per frame before packet metadata
```

Actual effective throughput depends on compression ratio, packet header overhead, repeated frames, MP4 codec behavior, and decode success rate.

## Validation

Run a basic transfer validation:

```bash
printf 'hello air gap\n' > sample_input.txt
./encode.sh sample_input.txt transfer.mp4
./decode.sh transfer.mp4 recovered.txt
cmp sample_input.txt recovered.txt
```

Run an adaptive generated-corpus study:

```bash
./ratio_harness.sh --suite ratio_reports/adaptive_binary_suite
```

Open the generated HTML report:

```bash
xdg-open ratio_reports/adaptive_binary_suite/report.html
```

## Limitations

- The transfer is not encrypted by default.
- MP4 compression can alter symbols and create decode failures at aggressive settings.
- Live camera decoding expects the encoded grid to be well aligned and mostly fill the camera view.
- Size-ratio results are empirical and depend on local OpenCV, installed codecs, and system behavior.
- The adaptive harness reports the best verified result inside the configured trial budget, not a mathematical optimum.
- Large generated inputs, especially `100M`, can require substantial encode/decode time.
