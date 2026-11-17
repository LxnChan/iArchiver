"""Narrow, repeatable safety changes to the hash-locked libarchive source.

The upstream notices are preserved. Unexpected source text fails the build.
This does not claim a hard cap on the whole application's memory footprint.
"""
import hashlib
import pathlib


def apply_limits(libarchive: pathlib.Path) -> str:
    library = libarchive / "libarchive"
    patches = {
        "archive_read_support_filter_xz.c": [
            ("#define LZMA_MEMLIMIT\tUINT64_MAX", "#define LZMA_MEMLIMIT\t(UINT64_C(256) << 20) /* iArchiver decoder budget */"),
            ("ret = lzma_raw_decoder(&(xz->stream), filters);",
             "ret = lzma_raw_decoder_memusage(filters) > LZMA_MEMLIMIT ? LZMA_MEMLIMIT_ERROR : lzma_raw_decoder(&(xz->stream), filters); /* iArchiver */"),
        ],
        "archive_read_support_format_zip.c": [
            ("lzma_stream_decoder(&zip->zipx_lzma_stream, UINT64_MAX, 0)",
             "lzma_stream_decoder(&zip->zipx_lzma_stream, (UINT64_C(256) << 20), 0) /* iArchiver */"),
            ("lzma_alone_decoder(&zip->zipx_lzma_stream, 576 * ((uint64_t)1 << 20))",
             "lzma_alone_decoder(&zip->zipx_lzma_stream, (UINT64_C(256) << 20)) /* iArchiver */"),
        ],
    }
    for name, edits in patches.items():
        path = library / name
        original = path.read_text(encoding="utf-8")
        changed = original
        for old, new in edits:
            if new in changed:
                continue
            if changed.count(old) != 1:
                raise RuntimeError(f"Upstream decoder changed; review patch: {name}")
            changed = changed.replace(old, new)
        if changed != original:
            path.write_text(changed, encoding="utf-8", newline="\n")
    return hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()
