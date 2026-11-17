#ifndef IA_RAR_BRIDGE_H
#define IA_RAR_BRIDGE_H
#include "ArchiveCore.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct IARARReader IARARReader;
IARARReader *iarar_open(const char *const *, size_t, const char *, IACancelCallback,
    void *, char *, size_t);
int iarar_next(IARARReader *, IAEntry *);
int64_t iarar_read(IARARReader *, void *, size_t);
int iarar_skip(IARARReader *);
void iarar_workspace(IARARReader *, const char *, int64_t);
const char *iarar_error(const IARARReader *);
void iarar_close(IARARReader *);
#ifdef __cplusplus
}
#endif
#endif
