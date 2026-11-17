#include "SevenZipBridge.h"
#include "CPP/Common/MyWindows.h"
#include "CPP/Common/MyInitGuid.h"
#include "CPP/Common/MyCom.h"
#include "CPP/Common/UTFConvert.h"
#include "CPP/Windows/PropVariant.h"
#include "CPP/7zip/Archive/7z/7zHandler.h"
#include "CPP/7zip/IPassword.h"
#ifdef min
#undef min
#endif
#ifdef max
#undef max
#endif
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <string>
#include <vector>
#include <sys/stat.h>
#ifdef _WIN32
#include <io.h>
#define IA7_SEEK _fseeki64
#define IA7_TELL _ftelli64
HINSTANCE g_hInstance = NULL;
bool g_IsNT = true;
#else
#include <unistd.h>
#include <fcntl.h>
#define IA7_SEEK fseeko
#define IA7_TELL ftello
#endif

using NWindows::NCOM::CPropVariant;
static constexpr UInt64 kMemoryLimit = 256ULL << 20;
struct Control {
    IACancelCallback callback = nullptr;
    void *context = nullptr;
    bool cancelled() const { return callback && callback(context); }
};
static UString unicode(const char *text) {
    UString value;
    if (text) ConvertUTF8ToUnicode(AString(text), value);
    return value;
}
static std::string utf8(const wchar_t *text) {
    AString value;
    if (text) ConvertUnicodeToUTF8(UString(text), value);
    return std::string(value.Ptr(), value.Len());
}
static void copyError(char *output, size_t size, const std::string &text) {
    if (output && size) std::snprintf(output, size, "%s", text.c_str());
}
static FILE *openInput(const char *path) {
#ifdef _WIN32
    return std::fopen(path, "rb");
#else
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return nullptr;
    struct stat info;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode)) { close(fd); return nullptr; }
    FILE *file = fdopen(fd, "rb");
    if (!file) close(fd);
    return file;
#endif
}

class Input final : public IInStream, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_2(ISequentialInStream, IInStream)
public:
    struct Volume { std::string path; UInt64 start, size; };
    std::vector<Volume> volumes;
    Control control;
    UInt64 position = 0, total = 0;
    FILE *file = nullptr;
    size_t current = std::numeric_limits<size_t>::max();
    ~Input() { if (file) std::fclose(file); }
    bool open(const char *const *paths, size_t count) {
        for (size_t i = 0; i < count; ++i) {
            FILE *probe = openInput(paths[i]);
            if (!probe) return false;
            if (IA7_SEEK(probe, 0, SEEK_END)) { std::fclose(probe); return false; }
            const auto size = IA7_TELL(probe); std::fclose(probe);
            if (size < 0 || static_cast<UInt64>(size) > std::numeric_limits<UInt64>::max() - total) return false;
            volumes.push_back({paths[i], total, static_cast<UInt64>(size)}); total += size;
        }
        return true;
    }
};
Z7_COM7F_IMF(Input::Read(void *data, UInt32 size, UInt32 *processed)) {
    if (processed) *processed = 0;
    if (control.cancelled()) return E_ABORT;
    if (!size || position >= total) return S_OK;
    size_t index = 0;
    while (index < volumes.size() && position >= volumes[index].start + volumes[index].size) ++index;
    if (index == volumes.size()) return S_OK;
    if (index != current) {
        if (file) std::fclose(file);
        file = openInput(volumes[index].path.c_str()); current = index;
        if (!file) return E_FAIL;
    }
    if (IA7_SEEK(file, static_cast<Int64>(position - volumes[index].start), SEEK_SET)) return E_FAIL;
    const size_t wanted = static_cast<size_t>(std::min<UInt64>(size, volumes[index].start + volumes[index].size - position));
    const size_t count = std::fread(data, 1, wanted, file);
    if (count < wanted && std::ferror(file)) return E_FAIL;
    position += count; if (processed) *processed = static_cast<UInt32>(count);
    return S_OK;
}
Z7_COM7F_IMF(Input::Seek(Int64 offset, UInt32 origin, UInt64 *newPosition)) {
    UInt64 base;
    switch (origin) { case STREAM_SEEK_SET: base = 0; break; case STREAM_SEEK_CUR: base = position; break;
        case STREAM_SEEK_END: base = total; break; default: return E_INVALIDARG; }
    if ((offset < 0 && static_cast<UInt64>(-(offset + 1)) + 1 > base) ||
        (offset >= 0 && static_cast<UInt64>(offset) > std::numeric_limits<UInt64>::max() - base)) return E_INVALIDARG;
    position = offset < 0 ? base - (static_cast<UInt64>(-(offset + 1)) + 1) : base + static_cast<UInt64>(offset);
    if (newPosition) *newPosition = position;
    return S_OK;
}

class Output final : public IOutStream, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_2(ISequentialOutStream, IOutStream)
public:
    FILE *file = nullptr;
    bool owns = false;
    UInt64 written = 0, limit = 64ULL << 30;
    Control control;
    ~Output() { if (owns && file) std::fclose(file); }
};
Z7_COM7F_IMF(Output::Write(const void *data, UInt32 size, UInt32 *processed)) {
    if (processed) *processed = 0;
    if (control.cancelled()) return E_ABORT;
    if (size > limit - std::min(limit, written)) return E_OUTOFMEMORY;
    const size_t count = std::fwrite(data, 1, size, file);
    written += count;
    if (processed) *processed = static_cast<UInt32>(count);
    return count == size ? S_OK : E_FAIL;
}
Z7_COM7F_IMF(Output::Seek(Int64 offset, UInt32 origin, UInt64 *position)) {
    if (origin > 2 || IA7_SEEK(file, offset, static_cast<int>(origin))) return E_FAIL;
    const auto value = IA7_TELL(file);
    if (value < 0) return E_FAIL;
    if (position) *position = static_cast<UInt64>(value);
    return S_OK;
}
Z7_COM7F_IMF(Output::SetSize(UInt64 size)) {
#ifdef _WIN32
    return _chsize_s(_fileno(file), size) == 0 ? S_OK : E_FAIL;
#else
    return ftruncate(fileno(file), static_cast<off_t>(size)) == 0 ? S_OK : E_FAIL;
#endif
}

class OpenCallback final : public IArchiveOpenCallback, public ICryptoGetTextPassword,
    public IArchiveRequestMemoryUseCallback, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_3(IArchiveOpenCallback, ICryptoGetTextPassword, IArchiveRequestMemoryUseCallback)
public:
    UString password;
    Control control;
    bool askedPassword = false;
};
Z7_COM7F_IMF(OpenCallback::SetTotal(const UInt64 *, const UInt64 *)) { return control.cancelled() ? E_ABORT : S_OK; }
Z7_COM7F_IMF(OpenCallback::SetCompleted(const UInt64 *, const UInt64 *)) { return control.cancelled() ? E_ABORT : S_OK; }
Z7_COM7F_IMF(OpenCallback::CryptoGetTextPassword(BSTR *value)) {
    askedPassword = true;
    if (password.IsEmpty()) return E_ABORT;
    return StringToBstr(password, value);
}
Z7_COM7F_IMF(OpenCallback::RequestMemoryUse(UInt32, UInt32, UInt32, const wchar_t *, UInt64 required, UInt64 *allowed, UInt32 *answer)) {
    *allowed = kMemoryLimit;
    *answer = required <= kMemoryLimit ? NRequestMemoryAnswerFlags::k_Allow : NRequestMemoryAnswerFlags::k_SkipArc;
    return required <= kMemoryLimit ? S_OK : E_OUTOFMEMORY;
}

class ExtractCallback final : public IArchiveExtractCallback, public ICryptoGetTextPassword,
    public IArchiveRequestMemoryUseCallback, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_4(IProgress, IArchiveExtractCallback, ICryptoGetTextPassword, IArchiveRequestMemoryUseCallback)
public:
    Control control;
    UString password;
    UInt32 target = 0;
    CMyComPtr<ISequentialOutStream> stream;
    Int32 operationResult = NArchive::NExtract::NOperationResult::kOK;
};
Z7_COM7F_IMF(ExtractCallback::SetTotal(UInt64)) { return control.cancelled() ? E_ABORT : S_OK; }
Z7_COM7F_IMF(ExtractCallback::SetCompleted(const UInt64 *)) { return control.cancelled() ? E_ABORT : S_OK; }
Z7_COM7F_IMF(ExtractCallback::GetStream(UInt32 index, ISequentialOutStream **out, Int32 mode)) {
    *out = nullptr;
    if (control.cancelled()) return E_ABORT;
    if (index == target && mode == NArchive::NExtract::NAskMode::kExtract) { *out = stream; if (*out) (*out)->AddRef(); }
    return S_OK;
}
Z7_COM7F_IMF(ExtractCallback::PrepareOperation(Int32)) { return control.cancelled() ? E_ABORT : S_OK; }
Z7_COM7F_IMF(ExtractCallback::SetOperationResult(Int32 result)) { operationResult = result; return S_OK; }
Z7_COM7F_IMF(ExtractCallback::CryptoGetTextPassword(BSTR *value)) {
    if (password.IsEmpty()) return E_ABORT;
    return StringToBstr(password, value);
}
Z7_COM7F_IMF(ExtractCallback::RequestMemoryUse(UInt32, UInt32, UInt32, const wchar_t *, UInt64 required, UInt64 *allowed, UInt32 *answer)) {
    *allowed = kMemoryLimit;
    *answer = required <= kMemoryLimit ? NRequestMemoryAnswerFlags::k_Allow : NRequestMemoryAnswerFlags::k_SkipArc;
    return required <= kMemoryLimit ? S_OK : E_OUTOFMEMORY;
}

struct IA7Reader {
    CMyComPtr<IInArchive> archive;
    CMyComPtr<IInStream> input;
    Control control;
    UString password;
    UInt32 count = 0, next = 0;
    std::string path, error, workspace;
    UInt64 limit = 64ULL << 30;
    FILE *spool = nullptr;
    bool materialized = false;
    ~IA7Reader() { if (spool) std::fclose(spool); }
};

extern "C" IA7Reader *ia7_reader_open(const char *const *paths, size_t count, const char *password,
    IACancelCallback cancel, void *context, char *error, size_t errorSize) {
    try {
        auto result = std::make_unique<IA7Reader>(); result->control = {cancel, context}; result->password = unicode(password);
        auto *input = new Input(); result->input = input; input->control = result->control;
        if (!input->open(paths, count)) { copyError(error, errorSize, "Cannot open 7z input volumes."); return nullptr; }
        auto *handler = new NArchive::N7z::CHandler(); result->archive = handler;
        ISetProperties *settings = handler;
        const wchar_t *readerProperties[] = {L"memuse", L"mt"};
        CPropVariant readerValues[2]; readerValues[0] = kMemoryLimit; readerValues[1] = static_cast<UInt32>(1);
        if (settings->SetProperties(readerProperties, readerValues, 2) != S_OK) { copyError(error, errorSize, "Cannot configure 7z memory limits."); return nullptr; }
        auto *callback = new OpenCallback(); CMyComPtr<IArchiveOpenCallback> hold = callback;
        callback->password = result->password; callback->control = result->control;
        UInt64 scan = 0;
        const HRESULT status = result->archive->Open(result->input, &scan, hold);
        if (status != S_OK) {
            copyError(error, errorSize, callback->askedPassword ? "7z password is required or incorrect." : "Cannot open 7z archive (invalid data, unsupported method, or memory limit).");
            return nullptr;
        }
        result->archive->GetNumberOfItems(&result->count);
        if (result->count > 200000) { copyError(error, errorSize, "7z entry limit exceeded."); return nullptr; }
        return result.release();
    } catch (...) { copyError(error, errorSize, "7z allocation or codec failure."); return nullptr; }
}
extern "C" int ia7_reader_next(IA7Reader *r, IAEntry *entry) {
    try {
        if (r->control.cancelled()) return IA_CANCELLED;
        if (r->spool) { std::fclose(r->spool); r->spool = nullptr; }
        r->materialized = false;
        if (r->next >= r->count) return IA_END;
        const UInt32 index = r->next++;
        CPropVariant name, size, directory, encrypted, attributes, symlink, hardlink, mtime;
        r->archive->GetProperty(index, kpidPath, &name);
        r->archive->GetProperty(index, kpidSize, &size);
        r->archive->GetProperty(index, kpidIsDir, &directory);
        r->archive->GetProperty(index, kpidEncrypted, &encrypted);
        r->archive->GetProperty(index, kpidPosixAttrib, &attributes);
        r->archive->GetProperty(index, kpidSymLink, &symlink);
        r->archive->GetProperty(index, kpidHardLink, &hardlink);
        r->archive->GetProperty(index, kpidMTime, &mtime);
        r->path = name.vt == VT_BSTR ? utf8(name.bstrVal) : "data";
        std::replace(r->path.begin(), r->path.end(), '\\', '/');
        std::memset(entry, 0, sizeof(*entry));
        entry->path = r->path.c_str(); entry->size = size.vt == VT_UI8 && size.uhVal.QuadPart <= INT64_MAX ? static_cast<int64_t>(size.uhVal.QuadPart) : -1;
        entry->kind = directory.vt == VT_BOOL && directory.boolVal ? IA_DIRECTORY : IA_FILE;
        if ((symlink.vt == VT_BSTR && symlink.bstrVal) || (hardlink.vt == VT_BSTR && hardlink.bstrVal) ||
            (attributes.vt == VT_UI4 && (attributes.ulVal & 0170000) == 0120000)) entry->kind = IA_LINK;
        if (attributes.vt == VT_UI4) {
            const UInt32 type = attributes.ulVal & 0170000;
            if (type && type != 0100000 && type != 0040000 && type != 0120000) entry->kind = IA_SPECIAL;
        }
        entry->encrypted = encrypted.vt == VT_BOOL && encrypted.boolVal;
        if (mtime.vt == VT_FILETIME) {
            const UInt64 value = (static_cast<UInt64>(mtime.filetime.dwHighDateTime) << 32) | mtime.filetime.dwLowDateTime;
            entry->modified = value >= 116444736000000000ULL ? static_cast<int64_t>((value - 116444736000000000ULL) / 10000000) : 0;
        }
        return IA_OK;
    } catch (...) { r->error = "Cannot read 7z metadata."; return IA_FAILED; }
}
extern "C" void ia7_reader_workspace(IA7Reader *r, const char *path, int64_t limit) {
    r->workspace = path ? path : ""; r->limit = static_cast<UInt64>(std::max<int64_t>(0, limit));
}
extern "C" int64_t ia7_reader_read(IA7Reader *r, void *data, size_t size) {
    try {
        if (r->control.cancelled()) return IA_CANCELLED;
        if (!r->materialized) {
#ifdef _WIN32
            r->spool = std::tmpfile();
#else
            if (r->workspace.empty()) { r->error = "A protected extraction workspace is required."; return IA_FAILED; }
            std::string pattern = r->workspace + "/.7z-spool-XXXXXX";
            std::vector<char> mutablePattern(pattern.begin(), pattern.end()); mutablePattern.push_back(0);
            int fd = mkstemp(mutablePattern.data());
            if (fd >= 0) { unlink(mutablePattern.data()); r->spool = fdopen(fd, "w+b"); if (!r->spool) close(fd); }
#endif
            if (!r->spool) { r->error = "Cannot allocate temporary disk space for 7z decoding."; return IA_FAILED; }
            auto *output = new Output(); CMyComPtr<ISequentialOutStream> holdOutput = output;
            output->file = r->spool; output->control = r->control; output->limit = r->limit;
            auto *callback = new ExtractCallback(); CMyComPtr<IArchiveExtractCallback> hold = callback;
            callback->control = r->control; callback->password = r->password; callback->target = r->next - 1; callback->stream = holdOutput;
            const UInt32 index = r->next - 1;
            const HRESULT status = r->archive->Extract(&index, 1, 0, hold);
            if (status != S_OK || callback->operationResult != NArchive::NExtract::NOperationResult::kOK) {
                if (callback->operationResult == NArchive::NExtract::NOperationResult::kWrongPassword ||
                    (status == E_ABORT && !r->control.cancelled())) r->error = "7z password is required or incorrect.";
                else if (callback->operationResult == NArchive::NExtract::NOperationResult::kUnsupportedMethod) r->error = "7z compression method is not supported.";
                else if (status == E_OUTOFMEMORY) r->error = "7z safety limit exceeded.";
                else r->error = "7z checksum or data validation failed.";
                return r->control.cancelled() ? IA_CANCELLED : IA_FAILED;
            }
            if (std::fflush(r->spool) || IA7_SEEK(r->spool, 0, SEEK_SET)) { r->error = "Cannot read temporary 7z data."; return IA_FAILED; }
            r->materialized = true;
        }
        const size_t count = std::fread(data, 1, size, r->spool);
        if (count < size && std::ferror(r->spool)) { r->error = "Temporary 7z read failed."; return IA_FAILED; }
        return static_cast<int64_t>(count);
    } catch (...) { r->error = "7z memory or codec failure."; return IA_FAILED; }
}
extern "C" int ia7_reader_skip(IA7Reader *r) { return r->control.cancelled() ? IA_CANCELLED : IA_OK; }
extern "C" const char *ia7_reader_error(const IA7Reader *r) { return r->error.c_str(); }
extern "C" void ia7_reader_close(IA7Reader *r) { delete r; }

struct WriteItem { std::string source; UString path; UInt64 size; bool directory; int64_t modified; };
struct IA7Writer {
    std::string destination, error;
    std::vector<WriteItem> items;
    UString password;
    Control control;
    int level = 5;
    bool finished = false;
    IAProgressCallback progress = nullptr;
    void *progressContext = nullptr;
};
class UpdateCallback final : public IArchiveUpdateCallback, public ICryptoGetTextPassword2, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_3(IProgress, IArchiveUpdateCallback, ICryptoGetTextPassword2)
public:
    IA7Writer *writer = nullptr;
};
Z7_COM7F_IMF(UpdateCallback::SetTotal(UInt64)) { return writer->control.cancelled() ? E_ABORT : S_OK; }
Z7_COM7F_IMF(UpdateCallback::SetCompleted(const UInt64 *value)) {
    if (writer->control.cancelled()) return E_ABORT;
    if (value && writer->progress) writer->progress(static_cast<int64_t>(*value), writer->progressContext);
    return S_OK;
}
Z7_COM7F_IMF(UpdateCallback::GetUpdateItemInfo(UInt32, Int32 *data, Int32 *properties, UInt32 *index)) {
    if (data) *data = 1; if (properties) *properties = 1; if (index) *index = static_cast<UInt32>(-1); return S_OK;
}
Z7_COM7F_IMF(UpdateCallback::GetProperty(UInt32 index, PROPID id, PROPVARIANT *value)) {
    if (index >= writer->items.size()) return E_INVALIDARG;
    const auto &item = writer->items[index]; CPropVariant property;
    switch (id) {
        case kpidPath: property = item.path; break;
        case kpidIsDir: property = item.directory; break;
        case kpidSize: property = item.size; break;
        case kpidAttrib: property = static_cast<UInt32>(item.directory ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_ARCHIVE); break;
        case kpidIsAnti: property = false; break;
        default: break;
    }
    property.Detach(value); return S_OK;
}
Z7_COM7F_IMF(UpdateCallback::GetStream(UInt32 index, ISequentialInStream **stream)) {
    *stream = nullptr;
    if (writer->control.cancelled()) return E_ABORT;
    if (index >= writer->items.size()) return E_INVALIDARG;
    const auto &item = writer->items[index];
    if (item.directory) return S_OK;
    auto *input = new Input(); CMyComPtr<ISequentialInStream> hold = input;
    input->control = writer->control;
    const char *path = item.source.c_str();
    if (!input->open(&path, 1) || input->total != item.size) return E_FAIL;
    *stream = hold.Detach(); return S_OK;
}
Z7_COM7F_IMF(UpdateCallback::SetOperationResult(Int32 result)) { return result == 0 ? S_OK : E_FAIL; }
Z7_COM7F_IMF(UpdateCallback::CryptoGetTextPassword2(Int32 *defined, BSTR *value)) {
    *defined = writer->password.IsEmpty() ? 0 : 1;
    return StringToBstr(writer->password, value);
}
extern "C" IA7Writer *ia7_writer_open(const char *path, int level, const char *password, IACancelCallback cancel,
    void *context, char *error, size_t errorSize) {
    try {
        auto result = std::make_unique<IA7Writer>(); result->destination = path; result->level = std::clamp(level, 0, 9);
        result->password = unicode(password); result->control = {cancel, context}; return result.release();
    } catch (...) { copyError(error, errorSize, "Cannot allocate 7z writer."); return nullptr; }
}
extern "C" int ia7_writer_add(IA7Writer *w, const char *source, const char *path) {
    try {
        if (w->control.cancelled()) return IA_CANCELLED;
        if (w->finished || !ia_validate_path(path)) { w->error = "Unsafe archive entry path."; return IA_FAILED; }
#ifdef _WIN32
        struct _stat64 info;
        if (_stat64(source, &info)) { w->error = "Cannot read 7z input."; return IA_FAILED; }
        bool directory = (info.st_mode & _S_IFMT) == _S_IFDIR;
        bool regular = (info.st_mode & _S_IFMT) == _S_IFREG;
#else
        struct stat info;
        if (lstat(source, &info)) { w->error = "Cannot read 7z input."; return IA_FAILED; }
        bool directory = S_ISDIR(info.st_mode), regular = S_ISREG(info.st_mode);
#endif
        if (!directory && !regular) { w->error = "Links and special files cannot be archived."; return IA_FAILED; }
        w->items.push_back({source, unicode(path), directory ? 0 : static_cast<UInt64>(info.st_size), directory, static_cast<int64_t>(info.st_mtime)});
        if (w->items.size() > 200000) { w->error = "7z entry limit exceeded."; return IA_LIMIT; }
        return IA_OK;
    } catch (...) { w->error = "Cannot allocate 7z metadata."; return IA_FAILED; }
}
extern "C" int ia7_writer_finish(IA7Writer *w) {
    try {
        if (w->finished) return IA_OK;
        if (w->control.cancelled()) return IA_CANCELLED;
        for (const auto &item : w->items) {
#ifdef _WIN32
            struct _stat64 info;
            int status = _stat64(item.source.c_str(), &info);
#else
            struct stat info;
            int status = lstat(item.source.c_str(), &info);
#endif
            if (status || (!item.directory && static_cast<UInt64>(info.st_size) != item.size) ||
                static_cast<int64_t>(info.st_mtime) != item.modified) { w->error = "Input changed before 7z creation."; return IA_FAILED; }
        }
        auto *handler = new NArchive::N7z::CHandler(); CMyComPtr<IOutArchive> archive = handler;
        const wchar_t *names[] = {L"x", L"d", L"mt", L"s", L"he", L"memuse"};
        CPropVariant properties[6]; properties[0] = static_cast<UInt32>(w->level);
        properties[1] = L"8m"; properties[2] = static_cast<UInt32>(1);
        properties[3] = false; properties[4] = !w->password.IsEmpty();
        properties[5] = kMemoryLimit;
        ISetProperties *settings = handler;
        if (settings->SetProperties(names, properties, 6) != S_OK) { w->error = "Cannot configure 7z writer."; return IA_FAILED; }
        auto *output = new Output(); CMyComPtr<ISequentialOutStream> holdOutput = output;
        output->file = std::fopen(w->destination.c_str(), "w+b"); output->owns = true; output->control = w->control;
        if (!output->file) { w->error = "Cannot create 7z output."; return IA_FAILED; }
        auto *callback = new UpdateCallback(); CMyComPtr<IArchiveUpdateCallback> hold = callback; callback->writer = w;
        HRESULT status = archive->UpdateItems(holdOutput, static_cast<UInt32>(w->items.size()), hold);
        if (status != S_OK || std::fflush(output->file)) {
            w->error = "7z creation failed (source changed, codec error, or insufficient space).";
            return w->control.cancelled() ? IA_CANCELLED : IA_FAILED;
        }
        w->finished = true; return IA_OK;
    } catch (...) { w->error = "7z memory or codec failure."; return IA_FAILED; }
}
extern "C" void ia7_writer_progress(IA7Writer *w, IAProgressCallback callback, void *context) {
    w->progress = callback; w->progressContext = context;
}
extern "C" const char *ia7_writer_error(const IA7Writer *w) { return w->error.c_str(); }
extern "C" void ia7_writer_close(IA7Writer *w) { delete w; }
