"""Repeatable safety and filename fixes to the hash-locked libarchive source.

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
            ("const char *p, size_t extra_length, struct zip_entry* zip_entry)",
             "const char *p, size_t extra_length, struct zip_entry* zip_entry, unsigned long raw_name_crc)"),
            ("if (datasize < 5 || entry == NULL)",
             "if (datasize < 5 || entry == NULL || (unsigned char)p[offset] != 1) /* iArchiver: supported Unicode Path version */"),
            ("const char *cp = archive_entry_pathname(entry);\n\t\t\t\tif (cp) {\n\t\t\t\t\tunsigned long file_crc =\n\t\t\t\t\t    zip->crc32func(0, cp, strlen(cp));",
             "/* iArchiver: CRC covers original ZIP name bytes, before charset conversion. */\n\t\t\t\t{\n\t\t\t\t\tunsigned long file_crc = raw_name_crc;"),
            ("struct zip_entry zip_entry_central_dir;",
             "struct zip_entry zip_entry_central_dir;\n\tunsigned long raw_name_crc; /* iArchiver */"),
            ("if (zip_entry->zip_flags & ZIP_UTF8_NAME) {\n\t\t/* The filename is stored to be UTF-8. */",
             "raw_name_crc = zip->crc32func(0, h, filename_length); /* iArchiver */\n\tif (zip_entry->zip_flags & ZIP_UTF8_NAME) {\n\t\t/* The filename is stored to be UTF-8. */"),
            ("process_extra(a, entry, h, extra_length,\n\t    zip_entry)",
             "process_extra(a, entry, h, extra_length,\n\t    zip_entry, raw_name_crc)"),
            ("process_extra(a, entry, p + filename_length,\n\t\t    extra_length, zip_entry)",
             "process_extra(a, entry, p + filename_length,\n\t\t    extra_length, zip_entry, zip->crc32func(0, p, filename_length))"),
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
