/* UnRAR source code may be used in any software to handle
 * RAR archives without limitations free of charge, but cannot be
 * used to develop RAR (WinRAR) compatible archiver and to
 * re-create RAR compression algorithm, which is proprietary.
 * Distribution of modified UnRAR source code in separate form
 * or as a part of other software is permitted, provided that
 * full text of this paragraph, starting from "UnRAR source code"
 * words, is included in license, or in documentation if license
 * is not available, and in source code comments of resulting package.
 *
 * This adapter is decode-only. It never invokes RAR_EXTRACT, writes a path
 * from an archive, or obtains an archive volume not in the supplied list.
 */
#include "RARBridge.h"
#include <algorithm>
#include <codecvt>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <locale>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#ifdef _WIN32
#include <windows.h>
#define IARAR_SEEK _fseeki64
#else
#define _UNIX
#include <unistd.h>
#define IARAR_SEEK fseeko
#endif
#include "dll.hpp"

static std::mutex rarMutex;
static std::wstring toWide(const std::string &value) {
#ifdef _WIN32
    return std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>>().from_bytes(value);
#else
    return std::wstring_convert<std::codecvt_utf8<wchar_t>>().from_bytes(value);
#endif
}
static std::string toUTF8(const std::wstring &value) {
#ifdef _WIN32
    return std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>>().to_bytes(value);
#else
    return std::wstring_convert<std::codecvt_utf8<wchar_t>>().to_bytes(value);
#endif
}
static std::wstring basename(const std::wstring &path) {
    const size_t slash = path.find_last_of(L"/\\");
    return slash == std::wstring::npos ? path : path.substr(slash + 1);
}
static std::string rarMessage(int code) {
    switch (code) {
        case ERAR_MISSING_PASSWORD: case ERAR_BAD_PASSWORD: return "RAR password is required or incorrect.";
        case ERAR_BAD_DATA: return "RAR checksum or data validation failed.";
        case ERAR_LARGE_DICT: case ERAR_NO_MEMORY: case ERAR_USER_LIMIT: return "RAR memory or safety limit exceeded.";
        case ERAR_EOPEN: return "Cannot open RAR input or a required volume is missing.";
        case ERAR_UNKNOWN_FORMAT: return "RAR compression method is not supported.";
        default: return "Cannot process RAR archive (code " + std::to_string(code) + ").";
    }
}
struct IARARReader {
    HANDLE archive = nullptr;
    IACancelCallback cancelled = nullptr;
    void *context = nullptr;
    std::vector<std::wstring> volumes;
    std::wstring password;
    std::string name, error, workspace;
    FILE *spool = nullptr;
    int64_t limit = 64LL << 30, written = 0;
    bool pending = false, materialized = false;
    bool isCancelled() const { return cancelled && cancelled(context); }
    ~IARARReader() { if (archive) RARCloseArchive(archive); if (spool) std::fclose(spool); }
};
static int CALLBACK rarCallback(UINT message, LPARAM opaque, LPARAM p1, LPARAM p2) {
    auto *r = reinterpret_cast<IARARReader *>(opaque);
    try {
    if (r->isCancelled()) return -1;
    if (message == UCM_NEEDPASSWORDW) {
        if (r->password.empty() || r->password.size() >= static_cast<size_t>(p2)) return -1;
        std::copy(r->password.begin(), r->password.end(), reinterpret_cast<wchar_t *>(p1));
        reinterpret_cast<wchar_t *>(p1)[r->password.size()] = 0;
        return 1;
    }
    if (message == UCM_NEEDPASSWORD) return -1; // Require the lossless wide callback.
    if (message == UCM_PROCESSDATA) {
        if (!r->spool || p2 < 0 || p2 > r->limit - r->written) { r->error = "RAR safety limit exceeded."; return -1; }
        const size_t size = static_cast<size_t>(p2);
        if (std::fwrite(reinterpret_cast<const void *>(p1), 1, size, r->spool) != size) { r->error = "Cannot write temporary RAR data."; return -1; }
        r->written += static_cast<int64_t>(size);
        return 1;
    }
    if (message == UCM_CHANGEVOLUMEW || message == UCM_CHANGEVOLUME) {
        std::wstring requested = message == UCM_CHANGEVOLUMEW ? std::wstring(reinterpret_cast<wchar_t *>(p1)) : toWide(reinterpret_cast<char *>(p1));
        for (const auto &allowed : r->volumes) {
            if (basename(allowed) == basename(requested)) {
                if (p2 == RAR_VOL_ASK) {
                    if (message == UCM_CHANGEVOLUMEW && allowed.size() < 1024) std::wcscpy(reinterpret_cast<wchar_t *>(p1), allowed.c_str());
                    else if (message == UCM_CHANGEVOLUME) {
                        const auto value = toUTF8(allowed);
                        if (value.size() >= 1024) return -1;
                        std::strcpy(reinterpret_cast<char *>(p1), value.c_str());
                    } else return -1;
                }
                return 1;
            }
        }
        r->error = "A required RAR volume was not selected.";
        return -1;
    }
    if (message == UCM_LARGEDICT) { r->error = "RAR memory limit exceeded."; return -1; }
    return 0;
    } catch (...) { r->error = "Cannot process RAR callback data."; return -1; }
}
extern "C" IARARReader *iarar_open(const char *const *paths, size_t count, const char *password,
    IACancelCallback cancel, void *context, char *error, size_t errorSize) {
    std::lock_guard<std::mutex> guard(rarMutex);
    try {
        auto result = std::make_unique<IARARReader>();
        result->cancelled = cancel; result->context = context;
        result->password = toWide(password ? password : "");
        for (size_t index = 0; index < count; ++index) result->volumes.push_back(toWide(paths[index]));
        if (result->volumes.empty()) return nullptr;
        RAROpenArchiveDataEx data{};
        data.ArcNameW = const_cast<wchar_t *>(result->volumes[0].c_str());
        data.OpenMode = RAR_OM_EXTRACT; data.Callback = rarCallback;
        data.UserData = reinterpret_cast<LPARAM>(result.get()); data.MaxAllocate = 256;
        result->archive = RAROpenArchiveEx(&data);
        if (!result->archive || data.OpenResult) {
            if (error && errorSize) std::snprintf(error, errorSize, "%s", rarMessage(data.OpenResult).c_str());
            return nullptr;
        }
        return result.release();
    } catch (...) { if (error && errorSize) std::snprintf(error, errorSize, "Cannot initialize RAR decoder."); return nullptr; }
}
extern "C" int iarar_next(IARARReader *r, IAEntry *entry) {
    std::lock_guard<std::mutex> guard(rarMutex);
    try {
        if (r->isCancelled()) return IA_CANCELLED;
        if (r->pending) { r->error = "Previous RAR entry was not consumed."; return IA_FAILED; }
        if (r->spool) { std::fclose(r->spool); r->spool = nullptr; }
        r->materialized = false; r->written = 0;
        RARHeaderDataEx header{}; std::vector<wchar_t> longName(4097);
        header.FileNameEx = longName.data(); header.FileNameExSize = static_cast<unsigned>(longName.size());
        int status = RARReadHeaderEx(r->archive, &header);
        if (status == ERAR_END_ARCHIVE) return IA_END;
        if (status) { r->error = rarMessage(status); return IA_FAILED; }
        r->name = toUTF8(longName[0] ? longName.data() : header.FileNameW);
        std::replace(r->name.begin(), r->name.end(), '\\', '/');
        std::memset(entry, 0, sizeof(*entry)); entry->path = r->name.c_str();
        uint64_t size = (static_cast<uint64_t>(header.UnpSizeHigh) << 32) | header.UnpSize;
        entry->size = size <= INT64_MAX ? static_cast<int64_t>(size) : -1;
        entry->kind = header.Flags & RHDF_DIRECTORY ? IA_DIRECTORY : IA_FILE;
        if (header.RedirType) entry->kind = IA_LINK;
        if (header.HostOS == 3 && (header.FileAttr & 0170000) != 0 && (header.FileAttr & 0170000) != 0100000 && (header.FileAttr & 0170000) != 0040000) entry->kind = IA_SPECIAL;
        entry->encrypted = (header.Flags & RHDF_ENCRYPTED) != 0;
        uint64_t time = (static_cast<uint64_t>(header.MtimeHigh) << 32) | header.MtimeLow;
        if (time >= 116444736000000000ULL) entry->modified = static_cast<int64_t>((time - 116444736000000000ULL) / 10000000);
        r->pending = true;
        return IA_OK;
    } catch (...) { r->error = "Cannot read RAR metadata."; return IA_FAILED; }
}
extern "C" int iarar_skip(IARARReader *r) {
    std::lock_guard<std::mutex> guard(rarMutex);
    if (r->isCancelled()) return IA_CANCELLED;
    if (!r->pending) return IA_OK;
    int result = RARProcessFileW(r->archive, RAR_SKIP, nullptr, nullptr); r->pending = false;
    if (result) { r->error = rarMessage(result); return IA_FAILED; }
    return IA_OK;
}
extern "C" void iarar_workspace(IARARReader *r, const char *path, int64_t limit) {
    r->workspace = path ? path : ""; r->limit = std::max<int64_t>(0, limit);
}
extern "C" int64_t iarar_read(IARARReader *r, void *output, size_t size) {
    std::lock_guard<std::mutex> guard(rarMutex);
    if (r->isCancelled()) return IA_CANCELLED;
    if (!r->materialized) {
#ifdef _WIN32
        r->spool = std::tmpfile();
#else
        if (r->workspace.empty()) { r->error = "A protected extraction workspace is required."; return IA_FAILED; }
        std::string pattern = r->workspace + "/.rar-spool-XXXXXX";
        std::vector<char> temporary(pattern.begin(), pattern.end()); temporary.push_back(0);
        int fd = mkstemp(temporary.data());
        if (fd >= 0) { unlink(temporary.data()); r->spool = fdopen(fd, "w+b"); if (!r->spool) close(fd); }
#endif
        if (!r->spool) { r->error = "Cannot allocate temporary disk space for RAR decoding."; return IA_FAILED; }
        int result = RARProcessFileW(r->archive, RAR_TEST, nullptr, nullptr); r->pending = false;
        if (result) { if (r->error.empty()) r->error = rarMessage(result); return r->isCancelled() ? IA_CANCELLED : IA_FAILED; }
        if (std::fflush(r->spool) || IARAR_SEEK(r->spool, 0, SEEK_SET)) { r->error = "Cannot read temporary RAR data."; return IA_FAILED; }
        r->materialized = true;
    }
    size_t count = std::fread(output, 1, size, r->spool);
    if (count < size && std::ferror(r->spool)) { r->error = "Temporary RAR read failed."; return IA_FAILED; }
    return static_cast<int64_t>(count);
}
extern "C" const char *iarar_error(const IARARReader *r) { return r->error.c_str(); }
extern "C" void iarar_close(IARARReader *r) { std::lock_guard<std::mutex> guard(rarMutex); delete r; }
