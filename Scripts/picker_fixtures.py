"""Small-on-disk, valid 7z files for real document-picker UI regression tests."""
from __future__ import annotations
import pathlib
import struct
import zlib

FIXTURE_DIRECTORY = "Picker Fixtures"
LARGE_ARCHIVE = "iArchiver-CI-5GiB.7z"
ENTRY_NAME = "Picker ready.txt"
LARGE_SIZE = 5 * 1024 ** 3


def write_archive(destination: pathlib.Path, size: int = LARGE_SIZE) -> None:
    # One empty file: FilesInfo, EmptyStream, EmptyFile, UTF-16 name, two Ends.
    # The unused gap before NextHeader makes the source genuinely >4 GiB while
    # keeping CI fixture creation cheap. The real import still copies every byte.
    name = ENTRY_NAME.encode("utf-16le") + b"\0\0"
    next_header = (b"\x01\x05\x01\x0e\x01\x80\x0f\x01\x80\x11"
                   + bytes([len(name) + 1]) + b"\0" + name + b"\0\0")
    if size < 32 + len(next_header):
        raise ValueError("Fixture size is smaller than its 7z headers")
    start_header = struct.pack("<QQI", size - 32 - len(next_header),
                               len(next_header), zlib.crc32(next_header))
    with destination.open("wb") as output:
        output.write(b"7z\xbc\xaf\x27\x1c\x00\x04")
        output.write(struct.pack("<I", zlib.crc32(start_header)))
        output.write(start_header)
        output.seek(size - len(next_header))
        output.write(next_header)
