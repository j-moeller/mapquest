#!/usr/bin/env python3
"""Compresses a building database for the app bundle.

Raw DEFLATE (no zlib header), as expected by NSData.decompressed(using: .zlib):

    python3 Tools/cities/deflate.py berlin-buildings.sqlite App/MapQuest/Resources/Berlin/berlin-buildings.sqlite.deflate
"""
import sys
import zlib


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit("usage: deflate.py INPUT OUTPUT")
    data = open(sys.argv[1], "rb").read()
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    packed = c.compress(data) + c.flush()
    open(sys.argv[2], "wb").write(packed)
    print(f"{len(data) / 1e6:.1f} MB -> {len(packed) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
