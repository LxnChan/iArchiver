#ifndef IARCHIVER_CORE_H
#define IARCHIVER_CORE_H
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct IAReader IAReader;
typedef struct IAWriter IAWriter;
typedef int (*IACancelCallback)(void *context);
typedef void (*IAProgressCallback)(int64_t completed, void *context);

enum { IA_OK = 0, IA_END = 1, IA_FAILED = -1, IA_CANCELLED = -2,
       IA_ENCODING = -3, IA_UNSUPPORTED = -4, IA_LIMIT = -5 };
enum { IA_FILE = 0, IA_DIRECTORY = 1, IA_LINK = 2, IA_SPECIAL = 3 };
enum { IA_ZIP = 0, IA_7Z = 1, IA_TAR = 2, IA_TAR_GZ = 3,
       IA_GZIP = 4, IA_ISO = 5 };

typedef struct {
    const char *path;
    int64_t size;
    int64_t modified;
    int kind;
    int encrypted;
} IAEntry;

const char *ia_version(void);
const char *ia_capabilities_json(void);
/* Paths must be in volume order. charset is an iconv name, NULL for auto. */
IAReader *ia_reader_open(const char *const *paths, size_t count,
    const char *charset, const char *password, IACancelCallback cancelled,
    void *context, char *error, size_t error_size);
int ia_reader_next(IAReader *reader, IAEntry *entry);
int64_t ia_reader_read(IAReader *reader, void *buffer, size_t length);
int ia_reader_skip(IAReader *reader);
void ia_reader_set_workspace(IAReader *reader, const char *directory, int64_t maximum_bytes);
const char *ia_reader_error(const IAReader *reader);
const char *ia_reader_format(const IAReader *reader);
int64_t ia_reader_bytes_read(IAReader *reader);
void ia_reader_close(IAReader *reader);

IAWriter *ia_writer_open(const char *destination, int format, int level,
    const char *password, IACancelCallback cancelled, void *context,
    char *error, size_t error_size);
/* Only regular files/directories; links and special files are rejected. */
int ia_writer_add(IAWriter *writer, const char *source, const char *entry_path,
    IAProgressCallback progress, void *progress_context);
int ia_writer_finish(IAWriter *writer);
const char *ia_writer_error(const IAWriter *writer);
void ia_writer_close(IAWriter *writer);

/* Validates archive-relative paths before a caller touches the filesystem. */
int ia_validate_path(const char *path);

#ifdef __cplusplus
}
#endif
#endif

