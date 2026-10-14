#!/usr/bin/env python3
"""证明一个下载下来的素材是原始产出，而不是截图或重新编码。

用法：python3 verify_asset_origin.py <file> [...]

输出：字节数、sha256、容器结构；PNG 且带 C2PA 时，列出出处标识
（截图 / 另存 / 重新编码都不会带签名块）。仅用标准库。
"""
import hashlib
import struct
import sys
from pathlib import Path

PNG_SIG = b"\x89PNG\r\n\x1a\n"
PROVENANCE_MARKERS = (b"c2pa", b"OpenAI", b"gpt-image", b"trainedAlgorithmicMedia", b"C2PA")


def png_chunks(data):
    """Yield (type, length, payload) for every chunk after the signature."""
    offset = 8
    while offset + 8 <= len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8].decode("latin1", "replace")
        yield kind, length, data[offset + 8:offset + 8 + length]
        offset += 12 + length


def describe(path):
    data = path.read_bytes()
    print(f"== {path}")
    print(f"   bytes : {len(data)}")
    print(f"   sha256: {hashlib.sha256(data).hexdigest()}")

    if data[:8] != PNG_SIG:
        print(f"   header: {data[:16].hex()} (not PNG)")
    else:
        for kind, length, payload in png_chunks(data):
            if kind == "IHDR":
                width, height, depth, color = struct.unpack(">IIBB", payload[:10])
                print(f"   IHDR  : {width}x{height} bitdepth={depth} colortype={color}")
            else:
                print(f"   {kind:<6}: {length} bytes")

    hits = sorted({marker.decode() for marker in PROVENANCE_MARKERS if marker in data})
    print("   provenance:", ", ".join(hits) if hits else "none — a screenshot or re-encode looks exactly like this")


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    for raw in argv:
        path = Path(raw)
        if not path.is_file():
            print(f"== {path}\n   missing")
            continue
        describe(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
