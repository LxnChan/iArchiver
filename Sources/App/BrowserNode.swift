import Foundation
import UniformTypeIdentifiers

struct BrowserNode: Identifiable, Hashable {
    let id: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    let isEncrypted: Bool
    let isSafe: Bool
    let localURL: URL?
    let archivePath: String?
    let entryIDs: Set<Int>
    var contentType: UTType? { UTType(filenameExtension: (name as NSString).pathExtension) }
    var symbol: String {
        if !isSafe { return "exclamationmark.shield" }
        if isDirectory { return "folder.fill" }
        if contentType?.conforms(to: .image) == true { return "photo" }
        if contentType?.conforms(to: .audio) == true { return "waveform" }
        if ["zip", "rar", "7z", "gz", "tar", "iso", "tgz"].contains((name as NSString).pathExtension.lowercased()) { return "archivebox" }
        return "doc"
    }
    static func local(_ item: LocalFileItem) -> BrowserNode {
        BrowserNode(id: item.url.path, name: item.name, isDirectory: item.isDirectory, size: item.size,
            modified: item.modified, isEncrypted: false, isSafe: !item.isSymbolicLink,
            localURL: item.url, archivePath: nil, entryIDs: [])
    }
    static func children(of path: String, in snapshot: ArchiveSnapshot, showHidden: Bool) -> [BrowserNode] {
        let prefix = path.isEmpty ? "" : path + "/"
        var groups: [String: [ArchiveEntry]] = [:]
        for entry in snapshot.entries {
            let normalized = (try? ExtractionPolicy.normalized(entry.path)) ?? entry.path
            guard normalized.hasPrefix(prefix) else { continue }
            let remainder = String(normalized.dropFirst(prefix.count))
            guard !remainder.isEmpty, let first = remainder.split(separator: "/", omittingEmptySubsequences: false).first else { continue }
            let name = String(first)
            if !showHidden && (name.hasPrefix(".") || name == "__MACOSX") { continue }
            groups[name, default: []].append(entry)
        }
        return groups.map { name, entries in
            let fullPath = prefix + name
            let exact = entries.first { (try? ExtractionPolicy.normalized($0.path)) == fullPath }
            let isDirectory = exact?.isDirectory == true || entries.contains { ((try? ExtractionPolicy.normalized($0.path)) ?? $0.path).hasPrefix(fullPath + "/") }
            let bytes = entries.reduce(Int64(0)) { total, entry in
                let value = total.addingReportingOverflow(max(0, entry.size))
                return value.overflow ? Int64.max : value.partialValue
            }
            return BrowserNode(id: fullPath, name: name, isDirectory: isDirectory, size: bytes,
                modified: exact?.modified ?? entries.first?.modified ?? .distantPast,
                isEncrypted: entries.contains(where: \.isEncrypted), isSafe: entries.allSatisfy(\.isSafe),
                localURL: nil, archivePath: fullPath, entryIDs: Set(entries.map(\.id)))
        }
    }
}

