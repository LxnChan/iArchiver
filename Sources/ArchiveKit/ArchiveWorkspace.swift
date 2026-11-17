import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ArchiveWorkspace {
    /// Exclusive creation also protects against aliases normalized by a File Provider.
    public static func createExclusiveFile(at url: URL) throws -> FileHandle {
        let descriptor = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600)) }
        guard descriptor >= 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    public static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ArchiveWork", isDirectory: true)
    }
    public static func makeStage() throws -> URL {
        let root = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = root
        try mutable.setResourceValues(values)
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
#endif
        return root
    }
    public static func checkSpace(at url: URL, required: Int64) throws {
        if let available = try availableBytes(at: url) {
            guard required >= 0, required <= available else { throw ArchiveFailure(.io, NSLocalizedString("error.space", comment: "")) }
        }
    }
    public static func availableBytes(at url: URL) throws -> Int64? {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        if let available = attributes[.systemFreeSize] as? NSNumber {
            let reserve: Int64 = 32 * 1024 * 1024
            return max(0, available.int64Value - reserve)
        }
        return nil
    }
    public static func removeStage(containing url: URL) {
        let root = cacheRoot.standardizedFileURL
        let path = url.standardizedFileURL
        guard path.path.hasPrefix(root.path + "/") else { return }
        let relative = String(path.path.dropFirst(root.path.count + 1))
        guard let first = relative.split(separator: "/").first, UUID(uuidString: String(first)) != nil else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(String(first)))
    }
    public static func cleanExpired(olderThan age: TimeInterval = 24 * 60 * 60) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for item in items {
            guard UUID(uuidString: item.lastPathComponent) != nil,
                  let date = try? item.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  Date().timeIntervalSince(date) > age else { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }
}
