#!/usr/bin/env python3
# Copyright (c) 2026 AztekMQ LLC (aztekmq.net) - Rob Lee
# All rights reserved.

"""
Visual MIMO Air-Gap Transfer MVP

A practical screen-to-camera file transfer proof-of-concept.

Modes:
  encode       file -> encoded mp4 video
  play         fullscreen video playback
  decode-video video -> recovered file
  decode-camera webcam -> recovered file

Design:
  - File is zstd-compressed.
  - Data is split into packets.
  - Each packet becomes one visual frame.
  - Each frame uses a fixed grid of cells.
  - Each cell carries 1, 2, 4, or 8 bits using luminance levels.
  - Packet header includes magic/version/packet index/count/original size/compressed size/crc32.
  - Decoder validates CRC32 and reassembles packets.

This is an MVP. It favors understandable engineering over record throughput.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import math
import os
import struct
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

import cv2
import numpy as np
try:
    import zstandard as zstd
except Exception:  # optional dependency fallback
    zstd = None
import zlib

MAGIC = b"VMIM"
VERSION = 1
HEADER_STRUCT = struct.Struct(">4sB B H H H I I Q Q I"
)
# magic, version, bits, cols, rows, payload_len, packet_index, packet_count,
# compressed_size, original_size, crc32
HEADER_LEN = HEADER_STRUCT.size

# A simple white/black locator border makes camera cropping easier for humans.
BORDER_CELLS = 2


@dataclass
class Packet:
    index: int
    total: int
    payload: bytes
    crc32: int


def crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def symbol_levels(bits_per_cell: int) -> np.ndarray:
    if bits_per_cell not in (1, 2, 4, 8):
        raise ValueError("bits_per_cell must be one of: 1, 2, 4, 8")
    levels = 2 ** bits_per_cell
    # Avoid pure black/white so border remains visually distinct.
    return np.linspace(32, 224, levels, dtype=np.uint8)


def bytes_to_symbols(data: bytes, bits_per_cell: int, symbol_count: int) -> np.ndarray:
    raw = int.from_bytes(data, "big") if data else 0
    total_bits = len(data) * 8
    mask = (1 << bits_per_cell) - 1
    symbols = []
    for bit_pos in range(total_bits - bits_per_cell, -bits_per_cell, -bits_per_cell):
        symbols.append((raw >> bit_pos) & mask)
    while len(symbols) < symbol_count:
        symbols.append(0)
    return np.array(symbols[:symbol_count], dtype=np.uint8)


def symbols_to_bytes(symbols: np.ndarray, bits_per_cell: int, byte_len: int) -> bytes:
    value = 0
    mask = (1 << bits_per_cell) - 1
    needed_symbols = math.ceil(byte_len * 8 / bits_per_cell)
    for sym in symbols[:needed_symbols]:
        value = (value << bits_per_cell) | (int(sym) & mask)
    extra_bits = needed_symbols * bits_per_cell - byte_len * 8
    if extra_bits:
        value >>= extra_bits
    return value.to_bytes(byte_len, "big") if byte_len else b""


def make_frame(
    packet_blob: bytes,
    cols: int,
    rows: int,
    cell: int,
    bits_per_cell: int,
) -> np.ndarray:
    symbol_count = cols * rows
    levels = symbol_levels(bits_per_cell)
    symbols = bytes_to_symbols(packet_blob, bits_per_cell, symbol_count)
    grid = levels[symbols].reshape(rows, cols)

    # Build image with border. Inner grid carries data only.
    h = (rows + BORDER_CELLS * 2) * cell
    w = (cols + BORDER_CELLS * 2) * cell
    img = np.zeros((h, w), dtype=np.uint8)
    img[:, :] = 255
    inner = img[BORDER_CELLS * cell : (BORDER_CELLS + rows) * cell,
                BORDER_CELLS * cell : (BORDER_CELLS + cols) * cell]
    # Expand each symbol cell into pixels.
    expanded = np.kron(grid, np.ones((cell, cell), dtype=np.uint8))
    inner[:, :] = expanded

    # Four black corner anchors just outside data grid.
    a = cell * BORDER_CELLS
    img[0:a, 0:a] = 0
    img[0:a, -a:] = 0
    img[-a:, 0:a] = 0
    img[-a:, -a:] = 0

    return cv2.cvtColor(img, cv2.COLOR_GRAY2BGR)


def sample_frame_to_symbols(
    frame: np.ndarray,
    cols: int,
    rows: int,
    bits_per_cell: int,
) -> np.ndarray:
    """Assumes the encoded video frame is directly available or roughly cropped.

    For live camera use, the current MVP asks the user to fill the camera view with the screen.
    A robust version should detect the border/corners and perspective-correct automatically.
    """
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY) if frame.ndim == 3 else frame
    h, w = gray.shape[:2]

    # Remove locator border by proportional crop.
    total_cols = cols + BORDER_CELLS * 2
    total_rows = rows + BORDER_CELLS * 2
    x0 = round(w * BORDER_CELLS / total_cols)
    x1 = round(w * (BORDER_CELLS + cols) / total_cols)
    y0 = round(h * BORDER_CELLS / total_rows)
    y1 = round(h * (BORDER_CELLS + rows) / total_rows)
    data = gray[y0:y1, x0:x1]

    cell_w = data.shape[1] / cols
    cell_h = data.shape[0] / rows
    samples = []
    for r in range(rows):
        for c in range(cols):
            cx = int((c + 0.5) * cell_w)
            cy = int((r + 0.5) * cell_h)
            # sample a tiny center area for stability
            rad_x = max(1, int(cell_w * 0.2))
            rad_y = max(1, int(cell_h * 0.2))
            patch = data[max(0, cy-rad_y):min(data.shape[0], cy+rad_y+1),
                         max(0, cx-rad_x):min(data.shape[1], cx+rad_x+1)]
            samples.append(int(np.median(patch)))

    levels = symbol_levels(bits_per_cell).astype(np.int16)
    samples_arr = np.array(samples, dtype=np.int16)
    # nearest luminance level -> symbol
    distances = np.abs(samples_arr[:, None] - levels[None, :])
    return np.argmin(distances, axis=1).astype(np.uint8)


def pack_header(
    bits: int,
    cols: int,
    rows: int,
    payload_len: int,
    packet_index: int,
    packet_count: int,
    compressed_size: int,
    original_size: int,
    payload_crc32: int,
) -> bytes:
    return HEADER_STRUCT.pack(
        MAGIC, VERSION, bits, cols, rows, payload_len, packet_index, packet_count,
        compressed_size, original_size, payload_crc32
    )


def unpack_packet(blob: bytes) -> Tuple[dict, bytes]:
    header = blob[:HEADER_LEN]
    fields = HEADER_STRUCT.unpack(header)
    magic, version, bits, cols, rows, payload_len, packet_index, packet_count, compressed_size, original_size, payload_crc = fields
    if magic != MAGIC:
        raise ValueError("bad magic")
    if version != VERSION:
        raise ValueError(f"unsupported version {version}")
    payload = blob[HEADER_LEN:HEADER_LEN + payload_len]
    if crc32(payload) != payload_crc:
        raise ValueError("crc mismatch")
    meta = {
        "bits": bits,
        "cols": cols,
        "rows": rows,
        "payload_len": payload_len,
        "packet_index": packet_index,
        "packet_count": packet_count,
        "compressed_size": compressed_size,
        "original_size": original_size,
        "payload_crc32": payload_crc,
    }
    return meta, payload


def encode_file(args: argparse.Namespace) -> None:
    input_path = Path(args.input)
    output_path = Path(args.output)
    raw = input_path.read_bytes()
    compressed = (zstd.ZstdCompressor(level=args.zstd_level).compress(raw) if zstd else zlib.compress(raw, level=9))

    raw_bytes_per_frame = (args.cols * args.rows * args.bits_per_cell) // 8
    payload_capacity = raw_bytes_per_frame - HEADER_LEN
    if payload_capacity <= 0:
        raise SystemExit("Grid too small for packet header. Increase rows/cols or bits-per-cell.")

    packet_count = math.ceil(len(compressed) / payload_capacity)
    w = (args.cols + BORDER_CELLS * 2) * args.cell
    h = (args.rows + BORDER_CELLS * 2) * args.cell
    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    writer = cv2.VideoWriter(str(output_path), fourcc, args.fps, (w, h))
    if not writer.isOpened():
        raise SystemExit("Could not open video writer. Try output .avi or install ffmpeg/OpenCV codecs.")

    print(f"Input: {input_path} ({len(raw)} bytes)")
    print(f"Compressed: {len(compressed)} bytes")
    print(f"Grid: {args.cols}x{args.rows}, bits/cell={args.bits_per_cell}, payload/frame={payload_capacity} bytes")
    print(f"Frames: {packet_count}, video={w}x{h}@{args.fps}fps")

    for idx in range(packet_count):
        start = idx * payload_capacity
        payload = compressed[start:start + payload_capacity]
        header = pack_header(
            args.bits_per_cell, args.cols, args.rows, len(payload), idx, packet_count,
            len(compressed), len(raw), crc32(payload)
        )
        blob = header + payload
        # Fill remaining frame capacity with zeros to stabilize decoding.
        blob += b"\x00" * (raw_bytes_per_frame - len(blob))
        frame = make_frame(blob, args.cols, args.rows, args.cell, args.bits_per_cell)
        # Repeat each packet frame to help camera/video decoding reliability.
        for _ in range(args.repeat):
            writer.write(frame)

    # Add optional trailing white frames. This can help live camera capture, but
    # file-to-file transfers can set it to 0 to keep the video compact.
    white = np.full((h, w, 3), 255, dtype=np.uint8)
    for _ in range(args.tail_frames):
        writer.write(white)
    writer.release()
    print(f"Wrote: {output_path}")


def decode_frames(frames: Iterable[np.ndarray], output_path: Path, expected_cols: Optional[int], expected_rows: Optional[int], expected_bits: Optional[int]) -> None:
    packets: Dict[int, bytes] = {}
    meta_seen: Optional[dict] = None
    bad = 0
    seen = 0

    cols = expected_cols
    rows = expected_rows
    bits = expected_bits
    if cols is None or rows is None or bits is None:
        raise SystemExit("For this MVP decoder, provide --cols, --rows, and --bits-per-cell matching the encoder.")

    raw_bytes_per_frame = (cols * rows * bits) // 8

    for frame in frames:
        seen += 1
        try:
            symbols = sample_frame_to_symbols(frame, cols, rows, bits)
            blob = symbols_to_bytes(symbols, bits, raw_bytes_per_frame)
            meta, payload = unpack_packet(blob)
        except Exception:
            bad += 1
            continue

        idx = meta["packet_index"]
        if idx not in packets:
            packets[idx] = payload
            meta_seen = meta
            print(f"received packet {idx + 1}/{meta['packet_count']} ({len(packets)} unique)")
        if meta_seen and len(packets) >= meta_seen["packet_count"]:
            break

    if not meta_seen:
        raise SystemExit(f"No valid packets decoded. Frames seen={seen}, bad={bad}")

    missing = [i for i in range(meta_seen["packet_count"]) if i not in packets]
    if missing:
        raise SystemExit(f"Missing {len(missing)} packets: first missing {missing[:20]}. Frames seen={seen}, bad={bad}")

    compressed = b"".join(packets[i] for i in range(meta_seen["packet_count"]))
    compressed = compressed[:meta_seen["compressed_size"]]
    raw = (zstd.ZstdDecompressor().decompress(compressed, max_output_size=meta_seen["original_size"]) if zstd else zlib.decompress(compressed))
    output_path.write_bytes(raw)
    print(f"Recovered: {output_path} ({len(raw)} bytes). Frames seen={seen}, bad={bad}")


def iter_video(path: Path) -> Iterable[np.ndarray]:
    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        raise SystemExit(f"Could not open video: {path}")
    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                break
            yield frame
    finally:
        cap.release()


def decode_video(args: argparse.Namespace) -> None:
    decode_frames(iter_video(Path(args.input)), Path(args.output), args.cols, args.rows, args.bits_per_cell)


def iter_camera(camera_index: int) -> Iterable[np.ndarray]:
    cap = cv2.VideoCapture(camera_index)
    if not cap.isOpened():
        raise SystemExit(f"Could not open camera index {camera_index}")
    print("Camera decoding started. Press Ctrl+C to stop.")
    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                continue
            yield frame
    finally:
        cap.release()


def decode_camera(args: argparse.Namespace) -> None:
    decode_frames(iter_camera(args.camera), Path(args.output), args.cols, args.rows, args.bits_per_cell)


def play_video(args: argparse.Namespace) -> None:
    cap = cv2.VideoCapture(args.input)
    if not cap.isOpened():
        raise SystemExit(f"Could not open video {args.input}")
    cv2.namedWindow("Visual MIMO Sender", cv2.WND_PROP_FULLSCREEN)
    cv2.setWindowProperty("Visual MIMO Sender", cv2.WND_PROP_FULLSCREEN, cv2.WINDOW_FULLSCREEN)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    delay = max(1, int(1000 / fps))
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        cv2.imshow("Visual MIMO Sender", frame)
        key = cv2.waitKey(delay) & 0xFF
        if key in (27, ord("q")):
            break
    cap.release()
    cv2.destroyAllWindows()


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Visual MIMO screen-camera air-gap file transfer MVP")
    sub = p.add_subparsers(dest="cmd", required=True)

    enc = sub.add_parser("encode")
    enc.add_argument("input")
    enc.add_argument("output")
    enc.add_argument("--fps", type=int, default=30)
    enc.add_argument("--cols", type=int, default=96)
    enc.add_argument("--rows", type=int, default=54)
    enc.add_argument("--cell", type=int, default=10)
    enc.add_argument("--bits-per-cell", type=int, default=2, choices=[1, 2, 4, 8])
    enc.add_argument("--repeat", type=int, default=3, help="repeat each packet frame for reliability")
    enc.add_argument("--tail-frames", type=int, default=30, help="white frames appended after data frames")
    enc.add_argument("--zstd-level", type=int, default=3)
    enc.set_defaults(func=encode_file)

    play = sub.add_parser("play")
    play.add_argument("input")
    play.set_defaults(func=play_video)

    decv = sub.add_parser("decode-video")
    decv.add_argument("input")
    decv.add_argument("output")
    decv.add_argument("--cols", type=int, default=96)
    decv.add_argument("--rows", type=int, default=54)
    decv.add_argument("--bits-per-cell", type=int, default=2, choices=[1, 2, 4, 8])
    decv.set_defaults(func=decode_video)

    decc = sub.add_parser("decode-camera")
    decc.add_argument("output")
    decc.add_argument("--camera", type=int, default=0)
    decc.add_argument("--cols", type=int, default=96)
    decc.add_argument("--rows", type=int, default=54)
    decc.add_argument("--bits-per-cell", type=int, default=2, choices=[1, 2, 4, 8])
    decc.set_defaults(func=decode_camera)

    return p


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
