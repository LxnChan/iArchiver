#include "ArchiveCore.h"
#include "SevenZipBridge.h"
#if IA_SIDELOAD
#include "RARBridge.h"
#endif
#include <archive.h>
#include <archive_entry.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <wchar.h>
#include <limits.h>
#ifdef _WIN32
#include <io.h>
#define IA_OPEN _open
#define IA_READ _read
#define IA_CLOSE _close
#define IA_FSTAT _fstat64
#define IA_STAT struct _stat64
#define IA_BINARY _O_BINARY
#define IA_REG(m) (((m) & _S_IFMT) == _S_IFREG)
#define IA_DIR(m) (((m) & _S_IFMT) == _S_IFDIR)
#else
#include <unistd.h>
#define IA_OPEN open
#define IA_READ read
#define IA_CLOSE close
#define IA_FSTAT fstat
#define IA_STAT struct stat
#define IA_BINARY 0
#define IA_REG(m) S_ISREG(m)
#define IA_DIR(m) S_ISDIR(m)
#endif

#define IA_ERROR_SIZE 2048
#define IA_BUFFER_SIZE (128 * 1024)

struct IAReader {
    struct archive *archive;
    IA7Reader *sevenzip;
#if IA_SIDELOAD
    IARARReader *rar;
#endif
    IACancelCallback cancelled;
    void *context;
    char error[IA_ERROR_SIZE];
    char *gzip_name;
    int terminal;
};
struct IAWriter {
    struct archive *archive;
    IA7Writer *sevenzip;
    IACancelCallback cancelled;
    void *context;
    char error[IA_ERROR_SIZE];
    int format;
    int entries;
    int finished;
    int failed;
};

static void ia_copy_error(char *target, size_t size, const char *message) {
    if (target && size) snprintf(target, size, "%s", message ? message : "Archive operation failed.");
}
static int ia_reader_failure(IAReader *r) {
    ia_copy_error(r->error, sizeof(r->error), archive_error_string(r->archive));
    r->terminal = 1;
    return IA_FAILED;
}
static int ia_writer_failure(IAWriter *w, const char *message) {
    ia_copy_error(w->error, sizeof(w->error), message ? message : archive_error_string(w->archive));
    w->failed = 1;
    return IA_FAILED;
}
static int ia_is_cancelled(IACancelCallback callback, void *context) {
    return callback && callback(context);
}

/* Avoid passing through the process locale (which can lose non-BMP names on
 * Windows). libarchive can convert its wide-string representation directly. */
static int ia_set_entry_path(struct archive_entry *entry, const char *utf8) {
    size_t capacity = strlen(utf8) + 1, out = 0;
    wchar_t *wide = malloc(capacity * sizeof(*wide));
    if (!wide) return 0;
    const unsigned char *p = (const unsigned char *)utf8;
    while (*p) {
        uint32_t scalar = *p++;
        unsigned remaining = 0;
        uint32_t minimum = 0;
        if (scalar >= 0xc2 && scalar <= 0xdf) { scalar &= 0x1f; remaining = 1; minimum = 0x80; }
        else if (scalar >= 0xe0 && scalar <= 0xef) { scalar &= 0x0f; remaining = 2; minimum = 0x800; }
        else if (scalar >= 0xf0 && scalar <= 0xf4) { scalar &= 7; remaining = 3; minimum = 0x10000; }
        else if (scalar >= 0x80) { free(wide); return 0; }
        for (unsigned i = 0; i < remaining; i++) {
            if ((*p & 0xc0) != 0x80) { free(wide); return 0; }
            scalar = (scalar << 6) | (*p++ & 0x3f);
        }
        if (scalar < minimum || scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) { free(wide); return 0; }
#if WCHAR_MAX <= 0xffff
        if (scalar > 0xffff) {
            scalar -= 0x10000;
            wide[out++] = (wchar_t)(0xd800 | (scalar >> 10));
            wide[out++] = (wchar_t)(0xdc00 | (scalar & 0x3ff));
        } else
#endif
            wide[out++] = (wchar_t)scalar;
    }
    wide[out] = 0;
    archive_entry_copy_pathname_w(entry, wide);
    free(wide);
    return 1;
}

const char *ia_version(void) { return archive_version_string(); }
const char *ia_capabilities_json(void) {
#if IA_SIDELOAD
    return "{\"variant\":\"sideload\",\"read\":[\"zip\",\"7z\",\"rar\",\"rar5\",\"tar\",\"tar.gz\",\"gz\",\"iso\"],\"write\":[\"zip\",\"7z\",\"tar\",\"tar.gz\",\"gz\",\"iso\"],\"encrypted7z\":true,\"encryptedRAR\":true}";
#else
    return "{\"variant\":\"appstore\",\"read\":[\"zip\",\"7z\",\"rar\",\"rar5\",\"tar\",\"tar.gz\",\"gz\",\"iso\"],\"write\":[\"zip\",\"7z\",\"tar\",\"tar.gz\",\"gz\"],\"encrypted7z\":true,\"encryptedRAR\":false}";
#endif
}

int ia_validate_path(const char *path) {
    const unsigned char *p = (const unsigned char *)path;
    size_t component = 0, depth = 1, length = 0;
    if (!p || !*p || *p == '/' || *p == '\\') return 0;
    const unsigned char *start = p;
    for (; *p; p++, length++) {
        if (length >= 4096 || *p < 32 || *p == 127 || *p == ':' || *p == '\\') return 0;
        if (*p == '/') {
            if (component == 0 || (component == 1 && start[0] == '.') ||
                (component == 2 && start[0] == '.' && start[1] == '.')) return 0;
            if (++depth > 128) return 0;
            start = p + 1;
            component = 0;
        } else if (++component > 1024) return 0;
    }
    if ((component == 1 && start[0] == '.') || (component == 2 && start[0] == '.' && start[1] == '.')) return 0;
    return 1; /* A final slash is allowed for directory records. */
}

IAReader *ia_reader_open(const char *const *paths, size_t count,
    const char *charset, const char *password, IACancelCallback cancelled,
    void *context, char *error, size_t error_size) {
    if (!count || !paths) { ia_copy_error(error, error_size, "No archive was selected."); return NULL; }
    IAReader *r = calloc(1, sizeof(*r));
    if (!r) { ia_copy_error(error, error_size, "Insufficient memory."); return NULL; }
    r->archive = archive_read_new();
    r->cancelled = cancelled;
    r->context = context;
    if (!r->archive) { ia_copy_error(error, error_size, "Cannot create archive reader."); free(r); return NULL; }
    /* Deliberately register a narrow, auditable set, never external filters. */
    archive_read_support_filter_none(r->archive);
    archive_read_support_filter_gzip(r->archive);
    archive_read_support_filter_xz(r->archive);
    archive_read_support_filter_lzma(r->archive);
    archive_read_support_format_zip(r->archive);
    archive_read_support_format_rar(r->archive);
    archive_read_support_format_rar5(r->archive);
    archive_read_support_format_tar(r->archive);
    archive_read_support_format_iso9660(r->archive);
    /* RAW has a low bid, and is enabled only for a genuine gzip stream below. */
    FILE *probe = fopen(paths[0], "rb");
    unsigned char magic[6] = {0};
    if (probe) { fread(magic, 1, sizeof(magic), probe); fclose(probe); }
    if (!memcmp(magic, "\x37\x7a\xbc\xaf\x27\x1c", 6)) {
        archive_read_free(r->archive); r->archive = NULL;
        r->sevenzip = ia7_reader_open(paths, count, password, cancelled, context, error, error_size);
        if (!r->sevenzip) { free(r); return NULL; }
        return r;
    }
#if IA_SIDELOAD
    if (!memcmp(magic, "Rar!\x1a\x07", 6)) {
        archive_read_free(r->archive); r->archive = NULL;
        r->rar = iarar_open(paths, count, password, cancelled, context, error, error_size);
        if (!r->rar) { free(r); return NULL; }
        return r;
    }
#endif
    if (magic[0] == 0x1f && magic[1] == 0x8b) {
        archive_read_support_format_raw(r->archive);
        const char *base = strrchr(paths[0], '/');
        base = base ? base + 1 : paths[0];
        const char *backslash = strrchr(base, '\\');
        if (backslash) base = backslash + 1;
        size_t length = strlen(base);
        if (length > 3 && base[length - 3] == '.' && (base[length - 2] == 'g' || base[length - 2] == 'G') &&
            (base[length - 1] == 'z' || base[length - 1] == 'Z')) {
            r->gzip_name = malloc(length - 2);
            if (r->gzip_name) { memcpy(r->gzip_name, base, length - 3); r->gzip_name[length - 3] = 0; }
        }
    }
    if (password && *password && archive_read_add_passphrase(r->archive, password) < ARCHIVE_OK) goto fail;
    if (charset && *charset) {
        if (archive_read_set_format_option(r->archive, "zip", "hdrcharset", charset) < ARCHIVE_OK) goto fail;
        if (archive_read_set_format_option(r->archive, "tar", "hdrcharset", charset) < ARCHIVE_OK) goto fail;
        if (archive_read_set_format_option(r->archive, "rar", "hdrcharset", charset) < ARCHIVE_OK) goto fail;
    }
    const char **filenames = calloc(count + 1, sizeof(*filenames));
    if (!filenames) { ia_copy_error(error, error_size, "Insufficient memory."); ia_reader_close(r); return NULL; }
    for (size_t i = 0; i < count; i++) filenames[i] = paths[i];
    int result = archive_read_open_filenames(r->archive, filenames, IA_BUFFER_SIZE);
    free(filenames);
    if (result < ARCHIVE_OK) goto fail;
    return r;
fail:
    ia_copy_error(error, error_size, archive_error_string(r->archive));
    ia_reader_close(r);
    return NULL;
}

int ia_reader_next(IAReader *r, IAEntry *entry) {
    if (!r || !entry || r->terminal) return IA_FAILED;
#if IA_SIDELOAD
    if (r->rar) return iarar_next(r->rar, entry);
#endif
    if (r->sevenzip) return ia7_reader_next(r->sevenzip, entry);
    if (ia_is_cancelled(r->cancelled, r->context)) return IA_CANCELLED;
    struct archive_entry *native = NULL;
    int result = archive_read_next_header(r->archive, &native);
    if (result == ARCHIVE_EOF) return IA_END;
    if (result < ARCHIVE_WARN || !native) return ia_reader_failure(r);
    const char *name = archive_entry_pathname_utf8(native);
    if (!name) {
        ia_copy_error(r->error, sizeof(r->error), "Cannot decode filename. Choose a filename encoding and reopen the archive.");
        r->terminal = 1;
        return IA_ENCODING;
    }
    memset(entry, 0, sizeof(*entry));
    entry->path = name;
    if (archive_format(r->archive) == ARCHIVE_FORMAT_RAW && r->gzip_name && ia_validate_path(r->gzip_name)) entry->path = r->gzip_name;
    entry->size = archive_entry_size_is_set(native) ? archive_entry_size(native) : -1;
    entry->modified = archive_entry_mtime(native);
    entry->encrypted = archive_entry_is_encrypted(native) > 0;
    int type = archive_entry_filetype(native);
    if (archive_entry_symlink(native) || archive_entry_hardlink(native)) entry->kind = IA_LINK;
    else if (type == AE_IFDIR) entry->kind = IA_DIRECTORY;
    else if (type == AE_IFREG || type == 0) entry->kind = IA_FILE;
    else entry->kind = IA_SPECIAL;
    return IA_OK;
}
int64_t ia_reader_read(IAReader *r, void *buffer, size_t length) {
    if (!r || r->terminal) return IA_FAILED;
#if IA_SIDELOAD
    if (r->rar) return iarar_read(r->rar, buffer, length);
#endif
    if (r->sevenzip) return ia7_reader_read(r->sevenzip, buffer, length);
    if (ia_is_cancelled(r->cancelled, r->context)) return IA_CANCELLED;
    la_ssize_t result = archive_read_data(r->archive, buffer, length);
    if (result < 0) return ia_reader_failure(r);
    return (int64_t)result;
}
int ia_reader_skip(IAReader *r) {
    if (!r) return IA_FAILED;
#if IA_SIDELOAD
    if (r->rar) return iarar_skip(r->rar);
#endif
    if (r->sevenzip) return ia7_reader_skip(r->sevenzip);
    if (ia_is_cancelled(r->cancelled, r->context)) return IA_CANCELLED;
    int result = archive_read_data_skip(r->archive);
    return result < ARCHIVE_OK ? ia_reader_failure(r) : IA_OK;
}
void ia_reader_set_workspace(IAReader *r, const char *directory, int64_t maximum_bytes) {
    if (r && r->sevenzip) ia7_reader_workspace(r->sevenzip, directory, maximum_bytes);
#if IA_SIDELOAD
    if (r && r->rar) iarar_workspace(r->rar, directory, maximum_bytes);
#endif
}
const char *ia_reader_error(const IAReader *r) {
#if IA_SIDELOAD
    if (r && r->rar) return iarar_error(r->rar);
#endif
    return r ? (r->sevenzip ? ia7_reader_error(r->sevenzip) : r->error) : "Archive reader is unavailable.";
}
const char *ia_reader_format(const IAReader *r) {
#if IA_SIDELOAD
    if (r && r->rar) return "RAR / UnRAR";
#endif
    if (r && r->sevenzip) return "7-Zip / LZMA SDK";
    const char *name = r ? archive_format_name(r->archive) : NULL;
    return name ? name : "Archive";
}
int64_t ia_reader_bytes_read(IAReader *r) { return r && r->archive ? archive_filter_bytes(r->archive, -1) : 0; }
void ia_reader_close(IAReader *r) {
#if IA_SIDELOAD
    if (r && r->rar) iarar_close(r->rar);
#endif
    if (r) { if (r->archive) archive_read_free(r->archive); if (r->sevenzip) ia7_reader_close(r->sevenzip); free(r->gzip_name); free(r); }
}

IAWriter *ia_writer_open(const char *destination, int format, int level,
    const char *password, IACancelCallback cancelled, void *context,
    char *error, size_t error_size) {
    IAWriter *w = calloc(1, sizeof(*w));
    if (!w) { ia_copy_error(error, error_size, "Insufficient memory."); return NULL; }
    w->archive = archive_write_new(); w->format = format;
    w->cancelled = cancelled; w->context = context;
    if (!w->archive) { ia_copy_error(error, error_size, "Cannot create archive writer."); free(w); return NULL; }
    if (format == IA_7Z) {
        archive_write_free(w->archive); w->archive = NULL;
        w->sevenzip = ia7_writer_open(destination, level, password, cancelled, context, error, error_size);
        if (!w->sevenzip) { free(w); return NULL; }
        return w;
    }
    int result = ARCHIVE_FATAL;
    switch (format) {
        case IA_ZIP: result = archive_write_set_format_zip(w->archive); break;
        case IA_TAR: case IA_TAR_GZ: result = archive_write_set_format_pax_restricted(w->archive); break;
        case IA_GZIP: result = archive_write_set_format_raw(w->archive); break;
#if IA_SIDELOAD
        case IA_ISO: result = archive_write_set_format_iso9660(w->archive); break;
#endif
        default: ia_copy_error(error, error_size, "This format cannot be created in this build."); ia_writer_close(w); return NULL;
    }
    if (result < ARCHIVE_OK) goto fail;
    if ((format == IA_TAR_GZ || format == IA_GZIP) && archive_write_add_filter_gzip(w->archive) < ARCHIVE_OK) goto fail;
    if (format == IA_ZIP || format == IA_7Z || format == IA_TAR_GZ || format == IA_GZIP) {
        char value[8]; snprintf(value, sizeof(value), "%d", level < 0 ? 0 : level > 9 ? 9 : level);
        if (archive_write_set_options(w->archive, "") < ARCHIVE_OK) goto fail;
        if (archive_write_set_option(w->archive, NULL, "compression-level", value) < ARCHIVE_OK) goto fail;
    }
    if (format == IA_ZIP) {
        if (archive_write_set_format_option(w->archive, "zip", "hdrcharset", "UTF-8") < ARCHIVE_OK) goto fail;
    }
    if (password && *password) {
        if (format != IA_ZIP) { ia_copy_error(error, error_size, "Password creation is currently available for ZIP only."); ia_writer_close(w); return NULL; }
        if (archive_write_set_passphrase(w->archive, password) < ARCHIVE_OK ||
            archive_write_set_format_option(w->archive, "zip", "encryption", "aes256") < ARCHIVE_OK) goto fail;
    }
    /* Avoid record padding and keep output deterministic at the archive layer. */
    archive_write_set_bytes_per_block(w->archive, 0);
    if (archive_write_open_filename(w->archive, destination) < ARCHIVE_OK) goto fail;
    return w;
fail:
    ia_copy_error(error, error_size, archive_error_string(w->archive));
    ia_writer_close(w);
    return NULL;
}

int ia_writer_add(IAWriter *w, const char *source, const char *path,
    IAProgressCallback progress, void *progress_context) {
    if (!w || w->finished || w->failed) return IA_FAILED;
    if (w->sevenzip) {
        ia7_writer_progress(w->sevenzip, progress, progress_context);
        return ia7_writer_add(w->sevenzip, source, path);
    }
    if (ia_is_cancelled(w->cancelled, w->context)) return IA_CANCELLED;
    if (!ia_validate_path(path)) return ia_writer_failure(w, "Unsafe archive entry path.");
    int flags = O_RDONLY | IA_BINARY;
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
    int fd = IA_OPEN(source, flags);
    IA_STAT metadata;
    if (fd < 0 || IA_FSTAT(fd, &metadata) != 0) {
        if (fd >= 0) IA_CLOSE(fd);
        /* POSIX opens directories read-only; Windows needs a separate stat. */
#ifdef _WIN32
        if (_stat64(source, &metadata) != 0 || !IA_DIR(metadata.st_mode))
#endif
            return ia_writer_failure(w, "Cannot read input file.");
    }
    if (!IA_REG(metadata.st_mode) && !IA_DIR(metadata.st_mode)) {
        if (fd >= 0) IA_CLOSE(fd);
        return ia_writer_failure(w, "Links and special files cannot be archived.");
    }
    if (w->format == IA_GZIP && (w->entries || IA_DIR(metadata.st_mode))) {
        if (fd >= 0) IA_CLOSE(fd);
        return ia_writer_failure(w, "Gzip requires exactly one regular file.");
    }
    struct archive_entry *entry = archive_entry_new();
    if (!entry) { if (fd >= 0) IA_CLOSE(fd); return ia_writer_failure(w, "Insufficient memory."); }
    if (!ia_set_entry_path(entry, path)) {
        archive_entry_free(entry); if (fd >= 0) IA_CLOSE(fd);
        return ia_writer_failure(w, "Invalid UTF-8 filename or insufficient memory.");
    }
    archive_entry_set_filetype(entry, IA_DIR(metadata.st_mode) ? AE_IFDIR : AE_IFREG);
    archive_entry_set_perm(entry, IA_DIR(metadata.st_mode) ? 0755 : 0644);
    archive_entry_set_size(entry, IA_DIR(metadata.st_mode) ? 0 : metadata.st_size);
    archive_entry_set_mtime(entry, metadata.st_mtime, 0);
    int result = archive_write_header(w->archive, entry);
    archive_entry_free(entry);
    if (result < ARCHIVE_OK) { if (fd >= 0) IA_CLOSE(fd); return ia_writer_failure(w, NULL); }
    int status = IA_OK;
    int64_t completed = 0;
    unsigned char *buffer = malloc(IA_BUFFER_SIZE);
    if (!buffer) { if (fd >= 0) IA_CLOSE(fd); return ia_writer_failure(w, "Insufficient memory."); }
    if (IA_REG(metadata.st_mode)) {
        while (1) {
            if (ia_is_cancelled(w->cancelled, w->context)) { status = IA_CANCELLED; break; }
            int64_t count = IA_READ(fd, buffer, IA_BUFFER_SIZE);
            if (count < 0) { status = ia_writer_failure(w, "Cannot read input file."); break; }
            if (!count) break;
            int64_t offset = 0;
            while (offset < count) {
                la_ssize_t written = archive_write_data(w->archive, buffer + offset, (size_t)(count - offset));
                if (written <= 0) { status = ia_writer_failure(w, NULL); break; }
                offset += written;
            }
            if (status != IA_OK) break;
            completed += count;
            if (progress) progress(completed, progress_context);
        }
        IA_STAT after;
        if (status == IA_OK && (completed != metadata.st_size || IA_FSTAT(fd, &after) != 0 ||
            after.st_size != metadata.st_size || after.st_mtime != metadata.st_mtime))
            status = ia_writer_failure(w, "Input changed while creating the archive. Please try again.");
    }
    free(buffer);
    if (fd >= 0) IA_CLOSE(fd);
    if (status == IA_OK && archive_write_finish_entry(w->archive) < ARCHIVE_OK) status = ia_writer_failure(w, NULL);
    if (status != IA_OK) w->failed = 1;
    w->entries++;
    return status;
}
int ia_writer_finish(IAWriter *w) {
    if (!w || w->failed) return IA_FAILED;
    if (w->sevenzip) return ia7_writer_finish(w->sevenzip);
    if (w->finished) return IA_OK;
    if (ia_is_cancelled(w->cancelled, w->context)) return IA_CANCELLED;
    if (w->format == IA_GZIP && w->entries != 1) return ia_writer_failure(w, "Gzip requires one file.");
    if (archive_write_close(w->archive) < ARCHIVE_OK) return ia_writer_failure(w, NULL);
    w->finished = 1;
    return IA_OK;
}
const char *ia_writer_error(const IAWriter *w) { return w ? (w->sevenzip ? ia7_writer_error(w->sevenzip) : w->error) : "Archive writer is unavailable."; }
void ia_writer_close(IAWriter *w) {
    if (w) { if (w->archive) archive_write_free(w->archive); if (w->sevenzip) ia7_writer_close(w->sevenzip); free(w); }
}
