"""Exercise the actual C ABI and locked compression libraries, not a mock."""
from __future__ import annotations
import binascii
import ctypes as C
import hashlib
import json
import os
import pathlib
import platform
import struct
import sys
import tempfile
import unittest
import zipfile
import lzma
import tarfile
import gzip
import unicodedata

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts"))
from picker_fixtures import ENTRY_NAME, write_archive


class Entry(C.Structure):
    _fields_ = [("path", C.c_char_p), ("size", C.c_int64), ("modified", C.c_int64),
                ("kind", C.c_int), ("encrypted", C.c_int)]


Cancel = C.CFUNCTYPE(C.c_int, C.c_void_p)
Progress = C.CFUNCTYPE(None, C.c_int64, C.c_void_p)
NEVER_CANCEL = Cancel(lambda _: 0)
ALWAYS_CANCEL = Cancel(lambda _: 1)
NO_PROGRESS = Progress(lambda _n, _c: None)


class Bridge:
    def __init__(self, variant="appstore"):
        directory = ROOT / "Build" / "native" / "host" / variant
        if platform.system() == "Windows":
            library = directory / "Release" / "ArchiveCore.dll"
        elif platform.system() == "Darwin":
            library = directory / "libArchiveCore.dylib"
        else:
            library = directory / "libArchiveCore.so"
        self.lib = C.CDLL(str(library))
        signatures = {
            "ia_version": ([], C.c_char_p),
            "ia_capabilities_json": ([], C.c_char_p),
            "ia_validate_path": ([C.c_char_p], C.c_int),
            "ia_reader_open": ([C.POINTER(C.c_char_p), C.c_size_t, C.c_char_p, C.c_char_p,
                                Cancel, C.c_void_p, C.c_void_p, C.c_size_t], C.c_void_p),
            "ia_reader_next": ([C.c_void_p, C.POINTER(Entry)], C.c_int),
            "ia_reader_read": ([C.c_void_p, C.c_void_p, C.c_size_t], C.c_int64),
            "ia_reader_skip": ([C.c_void_p], C.c_int),
            "ia_reader_set_workspace": ([C.c_void_p, C.c_char_p, C.c_int64], None),
            "ia_reader_error": ([C.c_void_p], C.c_char_p),
            "ia_reader_close": ([C.c_void_p], None),
            "ia_writer_open": ([C.c_char_p, C.c_int, C.c_int, C.c_char_p,
                                Cancel, C.c_void_p, C.c_void_p, C.c_size_t], C.c_void_p),
            "ia_writer_add": ([C.c_void_p, C.c_char_p, C.c_char_p, Progress, C.c_void_p], C.c_int),
            "ia_writer_finish": ([C.c_void_p], C.c_int),
            "ia_writer_error": ([C.c_void_p], C.c_char_p),
            "ia_writer_close": ([C.c_void_p], None),
        }
        for name, (args, restype) in signatures.items():
            function = getattr(self.lib, name)
            function.argtypes = args
            function.restype = restype

    def write(self, destination, sources, format=0, password=None, cancel=NEVER_CANCEL):
        error = C.create_string_buffer(2048)
        writer = self.lib.ia_writer_open(os.fsencode(destination), format, 5, password, cancel, None, error, len(error))
        if not writer:
            raise RuntimeError(error.value.decode("utf-8", "replace"))
        try:
            for source, name in sources:
                result = self.lib.ia_writer_add(writer, os.fsencode(source), name.encode(), NO_PROGRESS, None)
                if result:
                    raise RuntimeError(self.lib.ia_writer_error(writer).decode("utf-8", "replace"))
            if self.lib.ia_writer_finish(writer):
                raise RuntimeError(self.lib.ia_writer_error(writer).decode("utf-8", "replace"))
        finally:
            self.lib.ia_writer_close(writer)

    def read(self, sources, charset=None, password=None, cancel=NEVER_CANCEL, metadata_only=False,
             selection=None, spool_limit=64 << 30):
        error = C.create_string_buffer(2048)
        paths = (C.c_char_p * len(sources))(*(os.fsencode(x) for x in sources))
        reader = self.lib.ia_reader_open(paths, len(sources), charset, password, cancel, None, error, len(error))
        if not reader:
            raise RuntimeError(error.value.decode("utf-8", "replace"))
        result = {}
        self.lib.ia_reader_set_workspace(reader, os.fsencode(sources[0].parent), spool_limit)
        buffer = C.create_string_buffer(131072)
        try:
            while True:
                entry = Entry()
                status = self.lib.ia_reader_next(reader, C.byref(entry))
                if status == 1:
                    return result
                if status != 0:
                    raise RuntimeError(f"{status}: " + self.lib.ia_reader_error(reader).decode("utf-8", "replace"))
                name = entry.path.decode("utf-8", "strict")
                data = bytearray()
                if metadata_only or (selection is not None and name not in selection):
                    status = self.lib.ia_reader_skip(reader)
                    if status:
                        raise RuntimeError(self.lib.ia_reader_error(reader).decode("utf-8", "replace"))
                else:
                    while True:
                        count = self.lib.ia_reader_read(reader, buffer, len(buffer))
                        if count < 0:
                            raise RuntimeError(self.lib.ia_reader_error(reader).decode("utf-8", "replace"))
                        if count == 0:
                            break
                        data += buffer.raw[:count]
                result[name] = (bytes(data), entry.kind, entry.size)
        finally:
            self.lib.ia_reader_close(reader)


class RawNameZipInfo(zipfile.ZipInfo):
    def __init__(self, name, encoding):
        super().__init__(name)
        self.source_encoding = encoding

    def _encodeFilenameFlags(self):
        return self.filename.encode(self.source_encoding), self.flag_bits & ~0x800


def decode_fixture(name, destination):
    source = ROOT / ".deps" / "src" / "libarchive-3.8.11" / "libarchive" / "test" / (name + ".uu")
    lines = source.read_bytes().splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith(b"begin "))
    output = bytearray()
    for line in lines[start + 1:]:
        if line == b"end":
            break
        output += binascii.a2b_uu(line)
    destination.write_bytes(output)
    return destination


class CoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.store = Bridge()
        cls.side = Bridge("sideload")

    def setUp(self):
        # ASCII host paths let Windows test the same UTF-8 archive names as iOS.
        self.temp = tempfile.TemporaryDirectory(prefix="iarchiver-")
        self.root = pathlib.Path(self.temp.name)
        self.source = self.root / "source.bin"
        self.payload = b"iArchiver streaming round trip\n" * 10000 + bytes(range(256))
        self.source.write_bytes(self.payload)

    def tearDown(self):
        self.temp.cleanup()

    def test_document_picker_7z_fixture_is_readable(self):
        archive = self.root / "picker.7z"
        write_archive(archive, size=1024 * 1024)
        for bridge in [self.store, self.side]:
            self.assertEqual(bridge.read([archive]), {ENTRY_NAME: (b"", 0, 0)})

    def test_locked_version_and_actual_variant_capabilities(self):
        self.assertIn(b"3.8.11", self.store.lib.ia_version())
        store = json.loads(self.store.lib.ia_capabilities_json())
        side = json.loads(self.side.lib.ia_capabilities_json())
        self.assertNotIn("iso", store["write"])
        self.assertIn("iso", side["write"])
        self.assertTrue(store["encrypted7z"])
        self.assertFalse(store["encryptedRAR"])
        self.assertTrue(side["encryptedRAR"])
        with self.assertRaises(AttributeError):
            getattr(self.store.lib, "iarar_open")
        self.assertIsNotNone(getattr(self.side.lib, "iarar_open"))

    def test_sideload_encrypted_rar4_rar5_headers_and_solid_data(self):
        for version in (4, 5):
            for suffix in ("encrypted_filenames", "solid_encrypted", "solid_encrypted_filenames"):
                name = f"test_read_format_rar{version}_{suffix}.rar"
                with self.subTest(fixture=name):
                    archive = decode_fixture(name, self.root / name)
                    entries = self.side.read([archive], password=b"password")
                    for letter in "abcd":
                        self.assertEqual(entries[f"{letter}.txt"][0].strip(), f"This is from {letter}.txt".encode())
                    # Real extraction selects individual entries after metadata-only skips.
                    entries = self.side.read([archive], password=b"password", selection={"d.txt"})
                    self.assertEqual(entries["d.txt"][0].strip(), b"This is from d.txt")
                    with self.assertRaises(RuntimeError):
                        self.side.read([archive], password=b"wrong")
                    with self.assertRaises(RuntimeError):
                        self.side.read([archive])

    def test_sideload_rar_volumes_require_explicit_selection(self):
        for prefix, count, width in [("test_read_format_rar_multivolume", 4, 4),
                                     ("test_read_format_rar5_multiarchive_solid", 4, 2)]:
            with self.subTest(fixture=prefix):
                volumes = [decode_fixture(f"{prefix}.part{i:0{width}}.rar", self.root / f"{prefix}.part{i:0{width}}.rar")
                           for i in range(1, count + 1)]
                entries = self.side.read(volumes)
                self.assertTrue(any(v[0] for v in entries.values()))
                # Unselected next volumes exist on disk; the decoder must still refuse them.
                with self.assertRaises(RuntimeError):
                    self.side.read(volumes[:1])

    def test_spooled_decoders_obey_output_limits(self):
        destination = self.root / "limit.7z"
        self.store.write(destination, [(self.source, "data")], format=1)
        with self.assertRaises(RuntimeError):
            self.store.read([destination], spool_limit=100)
        name = "test_read_format_rar5_solid_encrypted.rar"
        rar = decode_fixture(name, self.root / name)
        with self.assertRaises(RuntimeError):
            self.side.read([rar], password=b"password", spool_limit=5)

    def test_roundtrip_required_writable_formats(self):
        for format, extension in [(0, "zip"), (1, "7z"), (2, "tar"), (3, "tar.gz"), (4, "gz")]:
            with self.subTest(format=extension):
                destination = self.root / ("roundtrip." + extension)
                self.store.write(destination, [(self.source, "资料/测试😀.bin")], format)
                entries = self.store.read([destination])
                files = [v[0] for v in entries.values() if v[1] == 0]
                self.assertEqual(files, [self.payload])
                if format != 4:
                    self.assertIn("资料/测试😀.bin", list(entries))

    def test_zip_aes256_and_wrong_password(self):
        destination = self.root / "aes.zip"
        self.store.write(destination, [(self.source, "secret.bin")], password=b"correct horse battery staple")
        self.assertNotIn(self.payload[:80], destination.read_bytes())
        self.assertEqual(self.store.read([destination], password=b"correct horse battery staple")["secret.bin"][0], self.payload)
        with self.assertRaises(RuntimeError):
            self.store.read([destination], password=b"incorrect")

    def test_created_plain_archives_are_readable_by_independent_standard_libraries(self):
        name = "资料/测试😀.bin"
        zip_path = self.root / "standard.zip"
        self.store.write(zip_path, [(self.source, name)])
        with zipfile.ZipFile(zip_path) as archive:
            self.assertEqual(archive.namelist(), [name])
            self.assertTrue(archive.getinfo(name).flag_bits & 0x800)
            self.assertEqual(archive.read(name), self.payload)
        for format, extension in [(2, "tar"), (3, "tar.gz")]:
            destination = self.root / ("standard." + extension)
            self.store.write(destination, [(self.source, name)], format=format)
            with tarfile.open(destination) as archive:
                self.assertEqual(archive.extractfile(name).read(), self.payload)
        destination = self.root / "standard.gz"
        self.store.write(destination, [(self.source, "file")], format=4)
        self.assertEqual(gzip.decompress(destination.read_bytes()), self.payload)

    def test_sevenzip_aes_and_encrypted_names(self):
        destination = self.root / "encrypted.7z"
        secret = "密码😀correct".encode()
        self.store.write(destination, [(self.source, "private/中文😀.bin")], format=1, password=secret)
        self.assertEqual(self.store.read([destination], password=secret)["private/中文😀.bin"][0], self.payload)
        self.assertNotIn("中文".encode("utf-16le"), destination.read_bytes())
        with self.assertRaises(RuntimeError):
            self.store.read([destination], password=b"wrong")
        with self.assertRaises(RuntimeError):
            self.store.read([destination])

    def test_sevenzip_byte_split_volumes_are_seekable(self):
        destination = self.root / "volumes.7z"
        self.store.write(destination, [(self.source, "file.bin")], format=1)
        data = destination.read_bytes()
        width = max(1, len(data) // 3)
        volumes = []
        for index, offset in enumerate(range(0, len(data), width)):
            volume = self.root / f"archive.7z.{index+1:03}"
            volume.write_bytes(data[offset:offset + width])
            volumes.append(volume)
        self.assertEqual(self.store.read(volumes)["file.bin"][0], self.payload)

    def test_legacy_chinese_big5_and_japanese_names(self):
        for codec, charset, name in [("gb18030", b"GB18030", "文件/简体中文.txt"),
                                     ("big5", b"BIG5", "檔案/繁體中文.txt"),
                                     ("cp932", b"CP932", "資料/テスト.txt"),
                                     ("cp437", b"CP437", "café.txt")]:
            with self.subTest(codec=codec):
                destination = self.root / (codec + ".zip")
                with zipfile.ZipFile(destination, "w") as archive:
                    archive.writestr(RawNameZipInfo(name, codec), b"legacy filename")
                entries = self.store.read([destination], charset=charset)
                # Darwin libarchive returns decomposed Unicode. Canonically
                # equivalent names must pass without ignoring mojibake.
                self.assertIn(name, {unicodedata.normalize("NFC", path) for path in entries})

    def test_store_rejects_iso_creation_but_sideload_roundtrips_it(self):
        destination = self.root / "image.iso"
        with self.assertRaisesRegex(RuntimeError, "cannot be created"):
            self.store.write(destination, [(self.source, "file.bin")], format=5)
        self.assertFalse(destination.exists())
        self.side.write(destination, [(self.source, "file.bin")], format=5)
        entries = self.store.read([destination])
        self.assertTrue(any(v[0] == self.payload for v in entries.values()))

    def test_paths_are_validated_before_creating_output(self):
        for bad in ["../escape", "/absolute", "C:/drive", "a/../../b", "a/./b", "a//b", "\\\\server\\share", "a\\..\\b", "a\nb", "", ".", "..", "x/" * 130 + "a"]:
            with self.subTest(path=repr(bad)):
                self.assertEqual(self.store.lib.ia_validate_path(bad.encode()), 0)
        for good in ["hello.txt", "文件/😀.txt", "a/b/c", "folder/"]:
            self.assertEqual(self.store.lib.ia_validate_path(good.encode()), 1)
        with self.assertRaisesRegex(RuntimeError, "Unsafe"):
            self.store.write(self.root / "unsafe.zip", [(self.source, "../escape")])

    def test_cancellation_is_observable(self):
        destination = self.root / "cancel.zip"
        self.store.write(destination, [(self.source, "file")])
        with self.assertRaisesRegex(RuntimeError, "-2"):
            self.store.read([destination], cancel=ALWAYS_CANCEL)

    def test_zip_crc_failure_is_not_success(self):
        destination = self.root / "broken.zip"
        with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_STORED) as archive:
            archive.writestr("file", b"original")
        raw = bytearray(destination.read_bytes())
        position = raw.find(b"original")
        raw[position] ^= 0x7F
        destination.write_bytes(raw)
        with self.assertRaises(RuntimeError):
            self.store.read([destination])

    def test_unicode_extra_field_requires_correct_name_crc(self):
        fixtures = ROOT / "Tests" / "ArchiveKitTests" / "Fixtures"
        for valid, expected in [(True, "标准名称😀.txt"), (False, "资料/简体中文.txt")]:
            name = "unicode-extra" + ("" if valid else "-invalid") + ".zip"
            entries = self.store.read([fixtures / name], charset=b"GB18030")
            self.assertIn(expected, entries)

    def test_zip64_archives_from_upstream(self):
        for suffix in ["a", "b"]:
            name = f"test_read_format_zip_zip64{suffix}.zip"
            archive = decode_fixture(name, self.root / name)
            self.assertGreater(len(self.store.read([archive])), 0)

    def test_large_lzma_dictionary_is_rejected_before_allocating_it(self):
        destination = self.root / "large-dictionary.zip"
        with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_LZMA) as archive:
            archive.writestr("file", b"small payload")
        raw = bytearray(destination.read_bytes())
        name_length, extra_length = struct.unpack_from("<HH", raw, 26)
        payload = 30 + name_length + extra_length
        struct.pack_into("<I", raw, payload + 5, 1 << 30)
        destination.write_bytes(raw)
        with self.assertRaisesRegex(RuntimeError, "memory|Memory|lzma"):
            self.store.read([destination])

    def test_gzip_restores_the_outer_basename_for_media_previews(self):
        destination = self.root / "audio.m4a.gz"
        self.store.write(destination, [(self.source, "audio.m4a")], format=4)
        self.assertEqual(self.store.read([destination])["audio.m4a"][0], self.payload)

    def test_unknown_data_is_not_misidentified_as_an_archive(self):
        self.source.write_bytes(b"This is not an archive.")
        with self.assertRaises(RuntimeError):
            self.store.read([self.source])

    def test_real_rar4_rar5_and_7z_fixtures(self):
        for name in ["test_read_format_rar_compress_normal.rar", "test_read_format_rar5_compressed.rar",
                     "test_read_format_7zip_lzma1.7z"]:
            with self.subTest(fixture=name):
                archive = decode_fixture(name, self.root / name)
                entries = self.store.read([archive])
                self.assertGreater(len(entries), 0)
                self.assertTrue(any(value[0] for value in entries.values()))

    def test_large_input_streams_and_preserves_hash(self):
        destination = self.root / "large.7z"
        block = hashlib.sha256(b"test stream").digest() * 32768
        expected = hashlib.sha256()
        with self.source.open("wb") as output:
            for _ in range(12):
                output.write(block)
                expected.update(block)
        self.store.write(destination, [(self.source, "large.bin")], format=1)
        result = self.store.read([destination])["large.bin"][0]
        self.assertEqual(hashlib.sha256(result).digest(), expected.digest())


if __name__ == "__main__":
    unittest.main(verbosity=2)
