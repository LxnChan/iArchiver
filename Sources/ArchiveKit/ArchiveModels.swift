import Foundation
import ArchiveCore

public enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable {
    case zip, sevenZip = "7z", tar, tarGzip = "tar.gz", gzip = "gz", iso
    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
    public var fileExtension: String { rawValue }
    var nativeValue: Int32 {
        switch self {
        case .zip: return Int32(IA_ZIP)
        case .sevenZip: return Int32(IA_7Z)
        case .tar: return Int32(IA_TAR)
        case .tarGzip: return Int32(IA_TAR_GZ)
        case .gzip: return Int32(IA_GZIP)
        case .iso: return Int32(IA_ISO)
        }
    }
    public static var writable: [ArchiveFormat] {
        allCases.filter { BuildCapabilities.current.write.contains($0.rawValue) }
    }
    public var supportsPasswordCreation: Bool { self == .zip || self == .sevenZip }
}

public enum FilenameEncoding: String, CaseIterable, Identifiable, Sendable {
    case automatic, utf8 = "UTF-8", gb18030 = "GB18030", gbk = "CP936"
    case big5 = "BIG5", shiftJIS = "CP932", cp437 = "CP437"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: return NSLocalizedString("encoding.auto", comment: "")
        case .gb18030: return "GB18030 · 简体中文"
        case .gbk: return "GBK / CP936 · 简体中文"
        case .big5: return "Big5 · 繁體中文"
        case .shiftJIS: return "Shift-JIS · 日本語"
        default: return rawValue
        }
    }
    var charset: String? { self == .automatic ? nil : rawValue }
}

public struct BuildCapabilities: Decodable, Sendable {
    public let variant: String
    public let read: [String]
    public let write: [String]
    public let encrypted7z: Bool
    public let encryptedRAR: Bool
    public var isSideload: Bool { variant == "sideload" }
    public static let current: BuildCapabilities = {
        let data = Data(String(cString: ia_capabilities_json()).utf8)
        guard let result = try? JSONDecoder().decode(BuildCapabilities.self, from: data) else {
            preconditionFailure("Invalid compiled archive capability manifest")
        }
        return result
    }()
    public static var engineVersion: String { String(cString: ia_version()) }
}

public struct ArchiveEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Int32, Sendable { case file = 0, directory, link, special }
    public let id: Int
    public let path: String
    public let size: Int64
    public let modified: Date
    public let kind: Kind
    public let isEncrypted: Bool
    public var name: String { (path as NSString).lastPathComponent }
    public var isDirectory: Bool { kind == .directory }
    public var isSafe: Bool { kind != .link && kind != .special && (try? ExtractionPolicy.normalized(path)) != nil }
}

public struct ArchiveSnapshot: Sendable {
    public let sourceURLs: [URL]
    public let entries: [ArchiveEntry]
    public let formatName: String
    public let encoding: FilenameEncoding
    public let encodingWasInferred: Bool
    public let sourceSizes: [Int64]
    public let sourceModified: [Date]
    public var totalSize: Int64 { entries.reduce(0) { $0.addingReportingOverflow(max(0, $1.size)).overflow ? Int64.max : $0 + max(0, $1.size) } }
}

public struct ArchiveProgress: Sendable {
    public let filename: String
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let completedEntries: Int
    public let totalEntries: Int
    public var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

public struct ArchiveFailure: LocalizedError, Sendable {
    public enum Reason: Equatable, Sendable { case engine, encoding, password, unsupported, unsafePath, limit, changed, io }
    public let reason: Reason
    public let detail: String
    public init(_ reason: Reason, _ detail: String = "") { self.reason = reason; self.detail = detail }
    public var errorDescription: String? {
        let key: String
        switch reason {
        case .engine: key = "error.archive"
        case .encoding: key = "error.encoding"
        case .password: key = "error.password"
        case .unsupported: key = "error.unsupported"
        case .unsafePath: key = "error.unsafe"
        case .limit: key = "error.limit"
        case .changed: key = "error.changed"
        case .io: key = "error.io"
        }
        let message = NSLocalizedString(key, comment: "")
        return detail.isEmpty ? message : message + "\n" + detail
    }
    static func native(_ detail: String, code: Int32 = Int32(IA_FAILED)) -> Error {
        if code == IA_CANCELLED { return CancellationError() }
        if code == IA_ENCODING { return ArchiveFailure(.encoding, detail) }
        let lower = detail.lowercased()
        if lower.contains("not supported") || lower.contains("unsupported") || lower.contains("unrecognized archive") || lower.contains("support unavailable") {
            return ArchiveFailure(.unsupported, detail)
        }
        if lower.contains("passphrase") || lower.contains("password") || lower.contains("decrypt") {
            return ArchiveFailure(.password, detail)
        }
        if lower.contains("limit exceeded") || lower.contains("memory limit") { return ArchiveFailure(.limit, detail) }
        return ArchiveFailure(.engine, detail)
    }
}

public struct ArchiveLimits: Sendable {
    public var maximumEntries: Int = 200_000
    public var maximumExpandedBytes: Int64 = 64 * 1024 * 1024 * 1024
    public var maximumRatio: Int64 = 5_000
    public var previewBytes: Int64 = 256 * 1024 * 1024
    public init() {}
}

