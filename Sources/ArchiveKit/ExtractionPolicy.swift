import Foundation
import ArchiveCore

public struct ExtractionPolicy {
    private var occupied: [String: ArchiveEntry.Kind] = [:]
    private var explicitPaths: Set<String> = []
    public init() {}

    public static func normalized(_ input: String) throws -> String {
        var path = input.replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.utf8.contains(0), path.withCString({ ia_validate_path($0) }) != 0 else {
            throw ArchiveFailure(.unsafePath, input)
        }
        return path
    }

    private static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Reserve parents as well, preventing case/Unicode aliases and file-as-directory conflicts.
    public mutating func reserve(_ entry: ArchiveEntry) throws -> String {
        guard entry.kind == .file || entry.kind == .directory else { throw ArchiveFailure(.unsafePath, entry.path) }
        let path = try Self.normalized(entry.path)
        let components = path.split(separator: "/").map(String.init)
        var current = ""
        for (index, component) in components.enumerated() {
            current = current.isEmpty ? component : current + "/" + component
            let key = Self.key(current)
            let isLeaf = index == components.count - 1
            let expected: ArchiveEntry.Kind = isLeaf ? entry.kind : .directory
            if let old = occupied[key], old != expected { throw ArchiveFailure(.unsafePath, entry.path) }
            if isLeaf && explicitPaths.contains(key) { throw ArchiveFailure(.unsafePath, entry.path) }
            // Aliased directory spellings could merge different archive trees on APFS.
            let spellingKey = "@" + key
            if let oldSpelling = spellings[spellingKey], !oldSpelling.utf8.elementsEqual(current.utf8) { throw ArchiveFailure(.unsafePath, entry.path) }
            spellings[spellingKey] = current
            occupied[key] = expected
            if isLeaf { explicitPaths.insert(key) }
        }
        return path
    }
    private var spellings: [String: String] = [:]

    public static func destination(root: URL, relative: String) throws -> URL {
        let path = try normalized(relative)
        let result = root.appendingPathComponent(path).standardizedFileURL
        let rootPath = root.standardizedFileURL.path + "/"
        guard result.path.hasPrefix(rootPath) else { throw ArchiveFailure(.unsafePath, relative) }
        return result
    }
}

