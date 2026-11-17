import Foundation
import CoreFoundation

public enum FilenameDetector {
    public struct Suggestion: Sendable {
        public let encoding: FilenameEncoding
        public let inferred: Bool
    }

    /// Samples ZIP central-directory names without decompressing file data.
    /// ZIP64 and unusual layouts safely fall back to the archive engine/manual override.
    public static func suggest(for url: URL, preferredLanguage: String = Locale.preferredLanguages.first ?? "en") -> Suggestion {
        guard let names = try? zipNames(url), !names.isEmpty else { return Suggestion(encoding: .automatic, inferred: false) }
        let undeclared = names.filter { $0.declared == nil }.map(\.raw)
        guard !undeclared.isEmpty else { return Suggestion(encoding: .automatic, inferred: false) }
        let nonASCII = undeclared.filter { $0.contains { $0 >= 128 } }
        guard !nonASCII.isEmpty else { return Suggestion(encoding: .utf8, inferred: false) }
        if nonASCII.allSatisfy({ String(data: $0, encoding: .utf8) != nil }) {
            return Suggestion(encoding: .utf8, inferred: false)
        }
        let candidates: [FilenameEncoding] = [.gb18030, .big5, .shiftJIS, .cp437]
        let ranked = candidates.compactMap { candidate -> (FilenameEncoding, Double)? in
            var total = 0.0
            for raw in nonASCII {
                guard let name = decode(raw, as: candidate) else { return nil }
                total += score(name, candidate: candidate, language: preferredLanguage)
            }
            return (candidate, total)
        }.sorted { $0.1 > $1.1 }
        return Suggestion(encoding: ranked.first?.0 ?? .cp437, inferred: true)
    }

    public static func samples(for url: URL, encoding: FilenameEncoding, limit: Int = 8) -> [String] {
        guard let names = try? zipNames(url) else { return [] }
        let selected = encoding == .automatic ? suggest(for: url).encoding : encoding
        return names.prefix(max(0, limit)).map { sample in
            sample.declared ?? decode(sample.raw, as: selected) ?? "0x" + sample.raw.prefix(64).map { String(format: "%02X", $0) }.joined()
        }
    }

    public static func decode(_ data: Data, as encoding: FilenameEncoding) -> String? {
        if encoding == .utf8 || encoding == .automatic { return String(data: data, encoding: .utf8) }
        let identifier: CFStringEncoding
        switch encoding {
        case .gb18030: identifier = 0x0632
        case .gbk: identifier = 0x0631
        case .big5: identifier = 0x0A03
        case .shiftJIS: identifier = 0x0420
        case .cp437: identifier = 0x0400
        default: return nil
        }
        return String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(identifier)))
    }

    private static func score(_ name: String, candidate: FilenameEncoding, language: String) -> Double {
        var score = 0.0
        for scalar in name.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF: score += 2
            case 0x3040...0x30FF: score += 3
            case 0x2500...0x259F: score -= 3
            case 0...31, 127...159, 0xFFFD: score -= 20
            default: break
            }
        }
        if language.hasPrefix("zh-Hant") && candidate == .big5 { score += 3 }
        else if language.hasPrefix("zh") && candidate == .gb18030 { score += 3 }
        if language.hasPrefix("ja") && candidate == .shiftJIS { score += 3 }
        if !language.hasPrefix("zh") && !language.hasPrefix("ja") && candidate == .cp437 { score += 1 }
        return score
    }

    private struct NameSample { let raw: Data; let declared: String? }
    private static func zipNames(_ url: URL) throws -> [NameSample] {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size >= 22 else { return [] }
        let start = size > 65_557 ? size - 65_557 : 0
        try file.seek(toOffset: start)
        let tail = try file.read(upToCount: Int(size - start)) ?? Data()
        guard tail.count >= 22 else { return [] }
        var eocd: Int?
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            if tail.u32(index) == 0x06054b50 && index + 22 + Int(tail.u16(index + 20)) == tail.count {
                eocd = index; break
            }
        }
        guard let end = eocd, tail.u16(end + 4) == 0, tail.u16(end + 6) == 0 else { return [] }
        let offset = tail.u32(end + 16)
        guard offset != UInt32.max, UInt64(offset) < size else { return [] }
        try file.seek(toOffset: UInt64(offset))
        var result: [NameSample] = []
        for _ in 0..<min(128, Int(tail.u16(end + 10))) {
            guard let header = try file.read(upToCount: 46), header.count == 46, header.u32(0) == 0x02014b50 else { break }
            let nameLength = Int(header.u16(28))
            let extraLength = Int(header.u16(30))
            let commentLength = Int(header.u16(32))
            guard let name = try file.read(upToCount: nameLength), name.count == nameLength else { break }
            // FileHandle may return nil for a zero-byte read; ZIP extras are
            // optional and an absent extra field must still yield a sample.
            let extra = try file.read(upToCount: extraLength) ?? Data()
            guard extra.count == extraLength else { break }
            var declared = header.u16(8) & 0x0800 != 0 ? String(data: name, encoding: .utf8) : nil
            var position = 0
            while position + 4 <= extra.count {
                let tag = extra.u16(position), length = Int(extra.u16(position + 2))
                let payload = position + 4
                guard payload + length <= extra.count else { break }
                if tag == 0x7075, length >= 5, extra[payload] == 1, extra.u32(payload + 1) == crc32(name),
                   let unicode = String(data: extra.subdata(in: (payload + 5)..<(payload + length)), encoding: .utf8) {
                    declared = unicode
                }
                position = payload + length
            }
            result.append(NameSample(raw: name, declared: declared))
            let current = try file.offset()
            guard current + UInt64(commentLength) <= size else { break }
            try file.seek(toOffset: current + UInt64(commentLength))
        }
        return result
    }
    private static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0) }
        }
        return ~crc
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}

