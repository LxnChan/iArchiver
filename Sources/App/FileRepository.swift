import Foundation
import UniformTypeIdentifiers

struct LocalFileItem: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64
    let modified: Date
    var name: String { url.lastPathComponent }
    var contentType: UTType? { UTType(filenameExtension: url.pathExtension) }
    var isArchive: Bool {
        ["zip", "7z", "rar", "tar", "gz", "tgz", "iso", "001"].contains(url.pathExtension.lowercased())
    }
    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        self.url = url
        isDirectory = values.isDirectory == true
        isSymbolicLink = values.isSymbolicLink == true
        size = Int64(values.fileSize ?? 0)
        modified = values.contentModificationDate ?? .distantPast
    }
}

enum FileRepository {
    enum ConflictBehavior: String, CaseIterable, Identifiable {
        case rename, skip, replace
        var id: String { rawValue }
        var key: String { "conflict." + rawValue }
    }
    struct ExportResult { let url: URL; let skipped: Bool }
    static var home: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static func prepare() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        ArchiveWorkspace.cleanExpired()
    }
    static func list(_ directory: URL, showHidden: Bool) async throws -> [LocalFileItem] {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: showHidden ? [] : [.skipsHiddenFiles]).map { try LocalFileItem(url: $0) }
        }.value
    }
    static func uniqueDestination(in directory: URL, name: String) -> URL {
        let original = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: original.path) { return original }
        let base = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent(base + " (\(index))" + (suffix.isEmpty ? "" : "." + suffix))
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
    static func importFiles(_ urls: [URL], asVolumes: Bool, control: JobControl) async throws -> [URL] {
        try await withTaskCancellationHandler {
          try await Task.detached(priority: .userInitiated) {
            let stage = try ArchiveWorkspace.makeStage()
            defer { ArchiveWorkspace.removeStage(containing: stage) }
            var staged: [URL] = []
            for url in urls {
                try control.check()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                var operationError: Error?
                var result: URL?
                coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readable in
                    do {
                        let target = uniqueDestination(in: stage, name: url.lastPathComponent)
                        guard !asVolumes || target.lastPathComponent == url.lastPathComponent else { throw ArchiveFailure(.unsafePath, url.lastPathComponent) }
                        try copyForImport(readable, to: target, control: control)
                        result = target
                    } catch { operationError = error }
                }
                if let error = coordinationError ?? operationError as NSError? { throw error }
                guard let result else { throw ArchiveFailure(.io) }
                staged.append(result)
            }
            try control.check()
            if asVolumes {
                // Preserve volume basenames together; numbered collision suffixes break RAR chains.
                let folder = uniqueDestination(in: home, name: urls.first?.deletingPathExtension().lastPathComponent ?? "Volumes")
                let names = staged.map(\.lastPathComponent)
                try FileManager.default.moveItem(at: stage, to: folder)
                return names.map { folder.appendingPathComponent($0) }
            }
            var imported: [URL] = []
            do {
                for item in staged {
                    let destination = uniqueDestination(in: home, name: item.lastPathComponent)
                    try FileManager.default.moveItem(at: item, to: destination)
                    imported.append(destination)
                }
                return imported
            } catch {
                for item in imported { try? FileManager.default.removeItem(at: item) }
                throw error
            }
          }.value
        } onCancel: { control.cancel() }
    }
    private static func copyForImport(_ source: URL, to destination: URL, control: JobControl, depth: Int = 0) throws {
        try control.check()
        guard depth < 128 else { throw ArchiveFailure(.limit) }
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isSymbolicLink != true else { throw ArchiveFailure(.unsafePath, source.lastPathComponent) }
        if values.isDirectory == true {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyForImport(child, to: destination.appendingPathComponent(child.lastPathComponent), control: control, depth: depth + 1)
            }
        } else {
            guard values.isRegularFile == true else { throw ArchiveFailure(.unsafePath, source.lastPathComponent) }
            try ArchiveWorkspace.checkSpace(at: destination.deletingLastPathComponent(), required: Int64(values.fileSize ?? 0))
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try ArchiveWorkspace.createExclusiveFile(at: destination)
            defer { try? output.close() }
            control.configure(filename: source.lastPathComponent, baseBytes: 0, totalBytes: Int64(values.fileSize ?? 0), index: 0, count: 0)
            var copied: Int64 = 0
            while true {
                try control.check()
                guard let data = try input.read(upToCount: 128 * 1024), !data.isEmpty else { break }
                try output.write(contentsOf: data)
                copied += Int64(data.count)
                control.report(copied)
            }
            try output.synchronize()
            let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard values.fileSize == after.fileSize, values.contentModificationDate == after.contentModificationDate else { throw ArchiveFailure(.changed) }
        }
        if let modified = values.contentModificationDate {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
        }
    }
    static func commit(_ staged: URL, name: String, directory: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let destination = uniqueDestination(in: directory, name: name)
            try FileManager.default.moveItem(at: staged, to: destination)
            ArchiveWorkspace.removeStage(containing: staged)
            return destination
        }.value
    }
    static func export(_ source: URL, to directory: URL, control: JobControl) async throws -> ExportResult {
        let behavior = ConflictBehavior(rawValue: UserDefaults.standard.string(forKey: "exportConflict") ?? "rename") ?? .rename
        return try await Task.detached(priority: .userInitiated) {
            let accessing = directory.startAccessingSecurityScopedResource()
            defer { if accessing { directory.stopAccessingSecurityScopedResource() } }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var operationError: Error?
            var result: ExportResult?
            coordinator.coordinate(writingItemAt: directory, options: [.forMerging], error: &coordinationError) { writable in
                let requested = writable.appendingPathComponent(source.lastPathComponent)
                let exists = FileManager.default.fileExists(atPath: requested.path)
                if exists && behavior == .skip { result = ExportResult(url: requested, skipped: true); return }
                let destination = behavior == .rename ? uniqueDestination(in: writable, name: source.lastPathComponent) : requested
                let staging = writable.appendingPathComponent(".iarchiver-export-" + UUID().uuidString)
                do {
                    try copyForImport(source, to: staging, control: control)
                    try control.check()
                    if exists && behavior == .replace {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
                    } else {
                        try FileManager.default.moveItem(at: staging, to: destination)
                    }
                    result = ExportResult(url: destination, skipped: false)
                } catch {
                    // Never delete the preexisting user item after a failed replacement.
                    try? FileManager.default.removeItem(at: staging)
                    operationError = error
                }
            }
            if let error = coordinationError ?? operationError as NSError? { throw error }
            guard let result else { throw ArchiveFailure(.io) }
            return result
        }.value
    }
    static func rename(_ source: URL, to name: String) throws {
        guard !name.contains("/"), (try? ExtractionPolicy.normalized(name)) == name else { throw ArchiveFailure(.unsafePath, name) }
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ArchiveFailure(.io, NSLocalizedString("error.exists", comment: "")) }
        try FileManager.default.moveItem(at: source, to: destination)
    }
}

