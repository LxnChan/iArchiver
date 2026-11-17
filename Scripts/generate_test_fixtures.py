"""Small deterministic fixtures; never derived from user documents."""
from __future__ import annotations
import pathlib
import stat
import zipfile
import struct
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Tests" / "ArchiveKitTests" / "Fixtures"


class LegacyName(zipfile.ZipInfo):
    def __init__(self, name, encoding):
        super().__init__(name, date_time=(2026, 1, 1, 0, 0, 0))
        self.encoding = encoding

    def _encodeFilenameFlags(self):
        return self.filename.encode(self.encoding), self.flag_bits & ~0x800


def generate():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for codec, name in [("gb18030", "资料/简体中文.txt"), ("big5", "檔案/繁體中文.txt"),
                        ("cp932", "資料/テスト.txt"), ("cp437", "café.txt")]:
        with zipfile.ZipFile(OUTPUT / f"legacy-{codec}.zip", "w") as archive:
            archive.writestr(LegacyName(name, codec), b"legacy text")
    for filename, names in {"traversal": ["../escape"], "case-collision": ["A/one", "a/two"],
                            "unicode-collision": ["caf\u00e9.txt", "cafe\u0301.txt"],
                            "file-parent": ["parent", "parent/child"],
                            "selection": ["small.txt", "other.txt"]}.items():
        with zipfile.ZipFile(OUTPUT / (filename + ".zip"), "w") as archive:
            for name in names:
                archive.writestr(zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0)), b"fixture content")
    with zipfile.ZipFile(OUTPUT / "link.zip", "w") as archive:
        info = zipfile.ZipInfo("symbolic-link", date_time=(2026, 1, 1, 0, 0, 0))
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(info, "../outside")
    for valid in [True, False]:
        name = "资料/简体中文.txt"
        raw = name.encode("gb18030")
        unicode = "标准名称😀.txt".encode()
        checksum = zlib.crc32(raw) if valid else 0
        info = LegacyName(name, "gb18030")
        payload = bytes([1]) + struct.pack("<I", checksum) + unicode
        info.extra = struct.pack("<HH", 0x7075, len(payload)) + payload
        with zipfile.ZipFile(OUTPUT / ("unicode-extra" + ("" if valid else "-invalid") + ".zip"), "w") as archive:
            archive.writestr(info, b"unicode metadata")
    print(f"Generated {len(list(OUTPUT.glob('*.zip')))} deterministic Swift fixtures.")


if __name__ == "__main__":
    generate()
