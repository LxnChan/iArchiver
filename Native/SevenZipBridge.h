#ifndef IA_SEVENZIP_BRIDGE_H
#define IA_SEVENZIP_BRIDGE_H
#include "ArchiveCore.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct IA7Reader IA7Reader;
typedef struct IA7Writer IA7Writer;
IA7Reader *ia7_reader_open(const char *const *paths, size_t count, const char *password,
    IACancelCallback cancel, void *context, char *error, size_t error_size);
int ia7_reader_next(IA7Reader *, IAEntry *);
int64_t ia7_reader_read(IA7Reader *, void *, size_t);
void ia7_reader_workspace(IA7Reader *, const char *, int64_t);
int ia7_reader_skip(IA7Reader *);
const char *ia7_reader_error(const IA7Reader *);
void ia7_reader_close(IA7Reader *);
IA7Writer *ia7_writer_open(const char *path, int level, const char *password,
    IACancelCallback cancel, void *context, char *error, size_t error_size);
int ia7_writer_add(IA7Writer *, const char *, const char *);
void ia7_writer_progress(IA7Writer *, IAProgressCallback, void *);
int ia7_writer_finish(IA7Writer *);
const char *ia7_writer_error(const IA7Writer *);
void ia7_writer_close(IA7Writer *);
#ifdef __cplusplus
}
#endif
#endif
