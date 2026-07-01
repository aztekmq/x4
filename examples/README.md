# Jovial Encode/Decode Demo

This demo tunes encoder parameters for `images/jovial.png`, then uses the best found settings to produce:
- `examples/jovial.mp4`
- `examples/jovial_decoded.png`

## Quick Start

Run from the repository root:

```bash
./examples/tune_jovial_for_smallest_mp4.sh
./examples/run_encode_jovial.sh
./examples/run_decode_jovial.sh
```

What each script does:
- `examples/tune_jovial_for_smallest_mp4.sh`: runs `ratio_harness.sh` against `images/jovial.png`, then writes best settings to `examples/jovial_best_params.env`.
- `examples/run_encode_jovial.sh`: loads `examples/jovial_best_params.env` if present and writes `examples/jovial.mp4`.
- `examples/run_decode_jovial.sh`: loads `examples/jovial_best_params.env` if present and writes `examples/jovial_decoded.png`.

## Outputs

- Tuned reports: `examples/ratio_reports/jovial_tuning_YYYYMMDD_HHMMSS/`
- Tuned params file: `examples/jovial_best_params.env`
- Encoded video: `examples/jovial.mp4`
- Decoded image: `examples/jovial_decoded.png`

## Original vs Decoded

| Original `images/jovial.png` | Checksum and Size | Decoded `examples/jovial_decoded.png` |
|---|---|---|
| ![Original jovial](../images/jovial.png) | SHA-256 (original): `3fa11108fadbc3aa23231acca3d07dd40ee2cf874a80c8230697ecb7d226dd96`  \
SHA-256 (decoded): `3fa11108fadbc3aa23231acca3d07dd40ee2cf874a80c8230697ecb7d226dd96`  \
Bytes (original): `3292985`  \
Bytes (decoded): `3292985`  \
Status: `match` | ![Decoded jovial](jovial_decoded.png) |

## Recompute Checksums and Byte Sizes

```bash
sha256sum images/jovial.png examples/jovial_decoded.png
stat -c '%n,%s bytes' images/jovial.png examples/jovial_decoded.png
```
