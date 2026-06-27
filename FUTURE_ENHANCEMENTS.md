# Future Enhancements: Python-First Acceleration Roadmap

This document describes a practical acceleration path for Visual MIMO while keeping the project primarily Python-based. The goal is to improve encode/decode throughput before considering a full C or C++ rewrite.

## Guiding Principle

Keep OpenCV as the video I/O and image-processing foundation. OpenCV is already implemented in optimized native code, so the highest-value work is reducing Python-level loops and conversion overhead around the codec path.

## Priority 1: Vectorize Symbol Packing

Target functions:

- `bytes_to_symbols`
- `symbols_to_bytes`

Current concern:

These functions perform bit packing and unpacking in Python-level logic. For larger transfers, repeated packet conversion can become expensive.

Recommended approach:

- Use NumPy byte arrays instead of Python integer shifts over entire payloads.
- Use `np.unpackbits` for byte-to-bit expansion.
- Reshape or group bit arrays according to `bits_per_cell`.
- Use vectorized dot products or bit masks to convert grouped bits into symbol values.
- Use `np.packbits` for symbol-to-byte reconstruction.

Expected benefit:

- Medium to high improvement for encode/decode conversion overhead.
- Best impact when many packets are processed.
- Lower implementation risk than changing frame sampling or codec behavior.

Validation requirements:

- Round-trip tests for `bits_per_cell` values `1`, `2`, `4`, and `8`.
- Payload lengths that are not aligned to symbol group boundaries.
- Empty payload behavior.
- Existing `encode -> decode -> cmp` smoke test.

## Priority 2: Vectorize Frame Sampling

Target function:

- `sample_frame_to_symbols`

Current concern:

The decoder samples each grid cell with nested Python loops. This is likely one of the most expensive pure-Python sections during decode.

Recommended approach:

- Crop the data region once.
- Resize or reshape the cropped region into a grid-aligned representation.
- Compute cell medians or means using vectorized NumPy operations.
- Map sampled luminance values to nearest symbol levels with broadcasting.

Candidate implementation strategies:

1. Use `cv2.resize` to reduce the cropped data region to `cols x rows`, then classify each reduced pixel.
2. Use reshape-based block reduction when the crop dimensions are exact multiples of `cols` and `rows`.
3. Use integral images or vectorized striding for robust center-patch sampling.

Expected benefit:

- High decode-side improvement.
- Potentially the best single optimization for large MP4 decode studies.

Risks:

- Sampling changes may affect decode reliability.
- Median sampling is more robust than mean sampling but can be more expensive.
- Camera-captured video may need more conservative sampling than direct MP4 decode.

Validation requirements:

- Compare decoded symbols against the current implementation on known-good MP4 frames.
- Run the adaptive harness before and after the change.
- Confirm that best-ratio results do not improve only because validation became less strict.
- Confirm byte-identical output with `cmp`.

## Priority 3: Add Optional JIT or Native Hot Path

Candidate tools:

- `numba`
- Cython
- `pybind11`

Recommended order:

1. Try NumPy vectorization first.
2. Use `numba` if a small numeric loop remains difficult to vectorize.
3. Use Cython or `pybind11` only if profiling shows a stable hotspot that justifies native extension maintenance.

Good candidates:

- Center-patch sampling loops.
- Symbol classification loops.
- Bit packing paths if NumPy implementation is not sufficient.

Expected benefit:

- Medium to high for specific hotspots.
- Lower engineering cost than a full C++ rewrite.

Risks:

- More complex dependency management.
- Build toolchain requirements.
- Potential portability friction for users.

Validation requirements:

- Native/JIT path must be optional.
- Pure Python/NumPy fallback must remain available.
- Output must match the reference path exactly.

## Priority 4: Keep OpenCV Video I/O

Current OpenCV responsibilities:

- MP4 writing through `cv2.VideoWriter`
- MP4 reading through `cv2.VideoCapture`
- Color conversion through `cv2.cvtColor`
- Playback window handling

Recommendation:

Do not replace OpenCV as part of the first optimization phase. The video codec path is already native and likely not the best place to spend effort until profiling proves otherwise.

Possible future work:

- Expose codec selection.
- Support lossless or near-lossless intermediate formats for research comparisons.
- Record codec metadata in harness reports.
- Compare MP4 against AVI or image-sequence transport for reliability and size.

## Profiling Plan

Use measurement before each optimization.

Suggested timing points:

- Compression time
- Packet construction time
- Symbol packing time
- Frame rendering time
- Video writer time
- Video reader time
- Frame sampling time
- Symbol unpacking time
- Decompression time

Recommended output:

- Add optional `--profile` output to `visual_mimo.py`.
- Add profile summary fields to `ratio_harness.sh` reports when available.

## Proposed Milestones

| Milestone | Scope | Success Criteria |
| --- | --- | --- |
| M1 | Vectorize `bytes_to_symbols` | Existing smoke tests pass; conversion benchmark improves. |
| M2 | Vectorize `symbols_to_bytes` | Decode output remains byte-identical for all supported bit depths. |
| M3 | Vectorize `sample_frame_to_symbols` | Adaptive harness produces valid decodes with lower decode time. |
| M4 | Add optional profiling | Reports identify encode/decode bottlenecks by phase. |
| M5 | Evaluate `numba` or native extension | Only proceed if profiling shows remaining Python loops dominate. |

## Recommended Next Step

Start with a small benchmark script around these three functions:

- `bytes_to_symbols`
- `symbols_to_bytes`
- `sample_frame_to_symbols`

Then implement one vectorized change at a time and run:

```bash
printf 'hello air gap\n' > sample_input.txt
./encode.sh sample_input.txt transfer.mp4
./decode.sh transfer.mp4 recovered.txt
cmp sample_input.txt recovered.txt
```

After functional validation, run:

```bash
MAX_TRIALS_PER_INPUT=40 ./ratio_harness.sh --suite ratio_reports/vectorization_baseline
```

Repeat the same harness run after each optimization and compare `summary.csv`, `trials.csv`, and runtime.
