import Foundation
import ArchiveCore
import Dispatch

private enum ArchiveWorkGate {
    private static let semaphore = DispatchSemaphore(value: 1)
    static func run<T>(control: JobControl, body: () throws -> T) throws -> T {
        while semaphore.wait(timeout: .now() + .milliseconds(100)) == .timedOut { try control.check() }
        defer { semaphore.signal() }
        try control.check()
        return try body()
    }
}

public struct LibarchiveEngine: Sendable {
    public var limits: ArchiveLimits
    public init(limits: ArchiveLimits = ArchiveLimits()) { self.limits = limits }

    public func list(urls: [URL], encoding: FilenameEncoding = .automatic, password: String = "",
                     control: JobControl = JobControl()) async throws -> ArchiveSnapshot {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try ArchiveWorkGate.run(control: control) {
                    try self.listSynchronously(urls: urls, encoding: encoding, password: password, control: control)
                }
            }.value
        } onCancel: { control.cancel() }
    }

    public func extract(_ snapshot: ArchiveSnapshot, selection: Set<Int>? = nil, password: String = "",
                        preview: Bool = false, control: JobControl = JobControl()) async throws -> URL {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try ArchiveWorkGate.run(control: control) {
                    try self.extractSynchronously(snapshot, selection: selection, password: password, preview: preview, control: control)
                }
            }.value
        } onCancel: { control.cancel() }
    }

    public func create(sources: [URL], name: String, format: ArchiveFormat, level: Int = 5,
                       password: String = "", control: JobControl = JobControl()) async throws -> URL {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try ArchiveWorkGate.run(control: control) {
                    try self.createSynchronously(sources: sources, name: name, format: format, level: level, password: password, control: control)
                }
            }.value
        } onCancel: { control.cancel() }
    }

    /// Produces a new archive with standard filenames and verifies it by decoding
    /// every output member. The original archive is never modified.
    public func repack(_ snapshot: ArchiveSnapshot, selection: Set<Int>? = nil, readingPassword: String = "",
                       name: String, format: ArchiveFormat = .zip, level: Int = 5, password: String = "",
                       control: JobControl = JobControl()) async throws -> URL {
        let expanded = try await extract(snapshot, selection: selection, password: readingPassword, control: control)
        defer { ArchiveWorkspace.removeStage(containing: expanded) }
        let sources = try FileManager.default.contentsOfDirectory(at: expanded, includingPropertiesForKeys: nil)
        let output = try await create(sources: sources, name: name, format: format, level: level, password: password, control: control)
        var succeeded = false
        defer { if !succeeded { ArchiveWorkspace.removeStage(containing: output) } }
        let rewritten = try await list(urls: [output], password: password, control: control)
        let verification = try await extract(rewritten, password: password, control: control)
        ArchiveWorkspace.removeStage(containing: verification)
        succeeded = true
        return output
    }

    private func listSynchronously(urls: [URL], encoding: FilenameEncoding, password: String, control: JobControl) throws -> ArchiveSnapshot {
        guard let first = urls.first else { throw ArchiveFailure(.io) }
        let suggestion = encoding == .automatic ? FilenameDetector.suggest(for: first) : .init(encoding: encoding, inferred: false)
        let fingerprints = try urls.map(FileFingerprint.init)
        let reader = try NativeReader(urls: urls, encoding: suggestion.encoding, password: password, control: control)
        var entries: [ArchiveEntry] = []
        var ordinal = 0
        while let entry = try reader.next(id: ordinal) {
            ordinal += 1
            try control.check()
            guard ordinal <= limits.maximumEntries else { throw ArchiveFailure(.limit, "Entry count exceeds \(limits.maximumEntries).") }
            if entry.kind == .directory && [".", "./", "/"].contains(entry.path) { try reader.skip(); continue }
            entries.append(entry)
            if ordinal % 100 == 0 { control.configure(filename: entry.path, baseBytes: 0, totalBytes: 0, index: ordinal, count: 0) }
            try reader.skip()
        }
        return ArchiveSnapshot(sourceURLs: urls, entries: entries, formatName: reader.format,
            encoding: suggestion.encoding, encodingWasInferred: suggestion.inferred,
            sourceSizes: fingerprints.map(\.size), sourceModified: fingerprints.map(\.modified))
    }

    private func extractSynchronously(_ snapshot: ArchiveSnapshot, selection: Set<Int>?, password: String,
                                      preview: Bool, control: JobControl) throws -> URL {
        for (index, url) in snapshot.sourceURLs.enumerated() {
            let fingerprint = try FileFingerprint(url)
            guard fingerprint.size == snapshot.sourceSizes[index], fingerprint.modified == snapshot.sourceModified[index] else {
                throw ArchiveFailure(.changed)
            }
        }
        let entries = snapshot.entries.filter { selection == nil || selection!.contains($0.id) }
        let expectedEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let byteLimit = preview ? min(limits.previewBytes, limits.maximumExpandedBytes) : limits.maximumExpandedBytes
        var policy = ExtractionPolicy()
        var destinations: [Int: String] = [:]
        var declaredTotal: Int64 = 0
        for entry in entries {
            destinations[entry.id] = try policy.reserve(entry)
            let addition = declaredTotal.addingReportingOverflow(max(0, entry.size))
            guard !addition.overflow, addition.partialValue <= byteLimit else { throw ArchiveFailure(.limit) }
            declaredTotal = addition.partialValue
        }
        let stage = try ArchiveWorkspace.makeStage()
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: stage) } }
        // SDK decoders spool one member before Swift writes its final destination.
        let largestMember = entries.map { max(0, $0.size) }.max() ?? 0
        let requiredSpace = declaredTotal.addingReportingOverflow(largestMember)
        guard !requiredSpace.overflow else { throw ArchiveFailure(.limit) }
        try ArchiveWorkspace.checkSpace(at: stage, required: requiredSpace.partialValue)
        let reader = try NativeReader(urls: snapshot.sourceURLs, encoding: snapshot.encoding, password: password, control: control)
        reader.setWorkspace(stage, maximumBytes: byteLimit)
        var ordinal = 0, completedEntries = 0
        var totalWritten: Int64 = 0
        let compressedSize = max(1, snapshot.sourceSizes.reduce(Int64(0)) { partial, value in
            let result = partial.addingReportingOverflow(value)
            return result.overflow ? Int64.max : result.partialValue
        })
        let ratioBudget = compressedSize.multipliedReportingOverflow(by: max(0, limits.maximumRatio))
        let expandedBudget = min(byteLimit, ratioBudget.overflow ? Int64.max : ratioBudget.partialValue)
        guard declaredTotal <= expandedBudget else { throw ArchiveFailure(.limit) }
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while let nativeEntry = try reader.next(id: ordinal) {
            let entryID = ordinal
            ordinal += 1
            try control.check()
            guard ordinal <= limits.maximumEntries else { throw ArchiveFailure(.limit) }
            guard let path = destinations[entryID] else { try reader.skip(); continue }
            // IDs alone are insufficient if a source/provider changed under the reader.
            guard let expected = expectedEntries[entryID], expected.path == nativeEntry.path,
                  expected.size == nativeEntry.size, expected.kind == nativeEntry.kind else { throw ArchiveFailure(.changed) }
            let destination = try ExtractionPolicy.destination(root: stage, relative: path)
            control.configure(filename: path, baseBytes: totalWritten, totalBytes: declaredTotal,
                              index: completedEntries, count: entries.count)
            if nativeEntry.kind == .directory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try reader.skip()
            } else {
                let remaining = expandedBudget - totalWritten
                let diskBudget = try ArchiveWorkspace.availableBytes(at: stage).map { $0 / 2 } ?? remaining
                let memberLimit = nativeEntry.size >= 0 ? min(remaining, nativeEntry.size) : min(remaining, diskBudget)
                reader.setWorkspace(stage, maximumBytes: memberLimit)
                let space = memberLimit.multipliedReportingOverflow(by: 2)
                guard !space.overflow else { throw ArchiveFailure(.limit) }
                try ArchiveWorkspace.checkSpace(at: stage, required: space.partialValue)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let file = try ArchiveWorkspace.createExclusiveFile(at: destination)
                do {
                    var entryWritten: Int64 = 0
                    while true {
                        try control.check()
                        let count = try reader.read(into: &buffer)
                        if count == 0 { break }
                        let nextTotal = totalWritten.addingReportingOverflow(Int64(count))
                        guard !nextTotal.overflow, nextTotal.partialValue <= expandedBudget else { throw ArchiveFailure(.limit) }
                        totalWritten = nextTotal.partialValue
                        entryWritten += Int64(count)
                        try file.write(contentsOf: Data(buffer[0..<count]))
                        control.report(entryWritten)
                    }
                    if nativeEntry.size >= 0 && entryWritten != nativeEntry.size { throw ArchiveFailure(.engine, "Unexpected extracted size: \(path)") }
                    try file.synchronize()
                    try file.close()
                } catch { try? file.close(); throw error }
                try? FileManager.default.setAttributes([.modificationDate: nativeEntry.modified], ofItemAtPath: destination.path)
            }
            completedEntries += 1
        }
        guard completedEntries == entries.count else { throw ArchiveFailure(.changed) }
        for (index, url) in snapshot.sourceURLs.enumerated() {
            let fingerprint = try FileFingerprint(url)
            guard fingerprint.size == snapshot.sourceSizes[index], fingerprint.modified == snapshot.sourceModified[index] else { throw ArchiveFailure(.changed) }
        }
        control.configure(filename: "", baseBytes: totalWritten, totalBytes: totalWritten,
                          index: completedEntries, count: entries.count)
        success = true
        return stage
    }

    private func createSynchronously(sources: [URL], name: String, format: ArchiveFormat, level: Int,
                                     password: String, control: JobControl) throws -> URL {
        guard !sources.isEmpty, ArchiveFormat.writable.contains(format) else { throw ArchiveFailure(.unsupported) }
        guard !name.contains("/"), (try? ExtractionPolicy.normalized(name)) == name else { throw ArchiveFailure(.unsafePath, name) }
        guard password.isEmpty || format.supportsPasswordCreation else { throw ArchiveFailure(.unsupported) }
        let inputs = try collectSources(sources, control: control)
        if format == .gzip && (inputs.count != 1 || inputs[0].directory) { throw ArchiveFailure(.unsupported, "GZ requires one regular file.") }
        let stage = try ArchiveWorkspace.makeStage()
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: stage) } }
        let output = stage.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
        let total = try inputs.reduce(Int64(0)) { total, input in
            let result = total.addingReportingOverflow(input.size)
            guard !result.overflow else { throw ArchiveFailure(.limit) }
            return result.partialValue
        }
        // Compression can increase size; reserve headroom rather than assume a ratio.
        let spoolAllowance = format == .iso ? total : 0
        let overhead = spoolAllowance.addingReportingOverflow(total / 20)
        guard !overhead.overflow else { throw ArchiveFailure(.limit) }
        let headroom = total.addingReportingOverflow(overhead.partialValue)
        guard !headroom.overflow else { throw ArchiveFailure(.limit) }
        try ArchiveWorkspace.checkSpace(at: stage, required: headroom.partialValue)
        let context = Unmanaged.passUnretained(control).toOpaque()
        var error = [CChar](repeating: 0, count: 2048)
        let errorCapacity = error.count
        let writer = withOptionalCString(password.isEmpty ? nil : password) { pass in
            output.path.withCString { ia_writer_open($0, format.nativeValue, Int32(level), pass, archiveCancelCallback, context, &error, errorCapacity) }
        }
        guard let writer else { try control.check(); throw ArchiveFailure.native(String(cString: error)) }
        defer { ia_writer_close(writer) }
        var completed: Int64 = 0
        for (index, input) in inputs.enumerated() {
            try control.check()
            guard try FileFingerprint(input.url) == input.fingerprint else { throw ArchiveFailure(.changed) }
            control.configure(filename: input.path, baseBytes: completed, totalBytes: total, index: index, count: inputs.count)
            let result = input.url.path.withCString { source in
                input.path.withCString { ia_writer_add(writer, source, $0, archiveProgressCallback, context) }
            }
            guard result == IA_OK else { try control.check(); throw ArchiveFailure.native(String(cString: ia_writer_error(writer)), code: result) }
            completed += input.size
        }
        if format == .sevenZip {
            control.configure(filename: output.lastPathComponent, baseBytes: 0, totalBytes: total, index: 0, count: inputs.count)
        }
        let result = ia_writer_finish(writer)
        guard result == IA_OK else { try control.check(); throw ArchiveFailure.native(String(cString: ia_writer_error(writer)), code: result) }
        for input in inputs where !input.directory {
            guard try FileFingerprint(input.url) == input.fingerprint else { throw ArchiveFailure(.changed) }
        }
        control.configure(filename: "", baseBytes: total, totalBytes: total, index: inputs.count, count: inputs.count)
        success = true
        return output
    }

    private struct Input {
        let url: URL
        let path: String
        let size: Int64
        let directory: Bool
        let fingerprint: FileFingerprint
    }
    private func collectSources(_ sources: [URL], control: JobControl) throws -> [Input] {
        var result: [Input] = []
        var policy = ExtractionPolicy()
        func append(_ url: URL, path: String) throws {
            try control.check()
            let metadata = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            guard metadata.isSymbolicLink != true, metadata.isDirectory == true || metadata.isRegularFile == true else { throw ArchiveFailure(.unsafePath, path) }
            let directory = metadata.isDirectory == true
            let entry = ArchiveEntry(id: result.count, path: path, size: Int64(metadata.fileSize ?? 0), modified: Date(), kind: directory ? .directory : .file, isEncrypted: false)
            let safePath = try policy.reserve(entry)
            result.append(Input(url: url, path: safePath, size: directory ? 0 : entry.size, directory: directory,
                                fingerprint: try FileFingerprint(url)))
            guard result.count <= limits.maximumEntries else { throw ArchiveFailure(.limit) }
            if directory {
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children { try append(child, path: path + "/" + child.lastPathComponent) }
            }
        }
        for url in sources { try append(url, path: url.lastPathComponent) }
        return result
    }
}

private final class NativeReader {
    private let handle: OpaquePointer
    private let control: JobControl
    init(urls: [URL], encoding: FilenameEncoding, password: String, control: JobControl) throws {
        self.control = control
        var error = [CChar](repeating: 0, count: 2048)
        let errorCapacity = error.count
        let result = withCStringArray(urls.map(\.path)) { paths in
            withOptionalCString(encoding.charset) { charset in
                withOptionalCString(password.isEmpty ? nil : password) { pass in
                    paths.withUnsafeBufferPointer {
                        ia_reader_open($0.baseAddress, $0.count, charset, pass, archiveCancelCallback,
                            Unmanaged.passUnretained(control).toOpaque(), &error, errorCapacity)
                    }
                }
            }
        }
        guard let result else { try control.check(); throw ArchiveFailure.native(String(cString: error)) }
        handle = result
    }
    deinit { ia_reader_close(handle) }
    var format: String { String(cString: ia_reader_format(handle)) }
    func setWorkspace(_ url: URL, maximumBytes: Int64) { url.path.withCString { ia_reader_set_workspace(handle, $0, maximumBytes) } }
    func next(id: Int) throws -> ArchiveEntry? {
        var entry = IAEntry()
        let result = ia_reader_next(handle, &entry)
        try control.check()
        if result == IA_END { return nil }
        guard result == IA_OK, let path = entry.path else { throw ArchiveFailure.native(String(cString: ia_reader_error(handle)), code: result) }
        return ArchiveEntry(id: id, path: String(cString: path), size: entry.size,
            modified: Date(timeIntervalSince1970: TimeInterval(entry.modified)),
            kind: ArchiveEntry.Kind(rawValue: entry.kind) ?? .special, isEncrypted: entry.encrypted != 0)
    }
    func skip() throws {
        let result = ia_reader_skip(handle)
        try control.check()
        guard result == IA_OK else { throw ArchiveFailure.native(String(cString: ia_reader_error(handle)), code: result) }
    }
    func read(into buffer: inout [UInt8]) throws -> Int {
        let result = buffer.withUnsafeMutableBytes { ia_reader_read(handle, $0.baseAddress, $0.count) }
        try control.check()
        guard result >= 0 else { throw ArchiveFailure.native(String(cString: ia_reader_error(handle)), code: Int32(result)) }
        return Int(result)
    }
}

private struct FileFingerprint: Equatable {
    let size: Int64
    let modified: Date
    init(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values.fileSize, let modified = values.contentModificationDate else { throw ArchiveFailure(.io, url.lastPathComponent) }
        self.size = Int64(size); self.modified = modified
    }
}

private func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
    if let value { return try value.withCString(body) }
    return try body(nil)
}
private func withCStringArray<T>(_ strings: [String], _ body: ([UnsafePointer<CChar>?]) throws -> T) rethrows -> T {
    let allocated = strings.map { value -> UnsafeMutablePointer<CChar> in
        let chars = Array(value.utf8CString)
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: chars.count)
        chars.withUnsafeBufferPointer { pointer.initialize(from: $0.baseAddress!, count: $0.count) }
        return pointer
    }
    defer { for pointer in allocated { pointer.deallocate() } }
    return try body(allocated.map { UnsafePointer($0) })
}

