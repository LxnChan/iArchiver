import Foundation

enum ArchivePreferences {
    static var limits: ArchiveLimits {
        let defaults = UserDefaults.standard
        var limits = ArchiveLimits()
        let expanded = defaults.integer(forKey: "expandedGiB")
        let preview = defaults.integer(forKey: "previewMiB")
        let entries = defaults.integer(forKey: "maximumEntries")
        if [4, 16, 64].contains(expanded) { limits.maximumExpandedBytes = Int64(expanded) << 30 }
        if [64, 128, 256].contains(preview) { limits.previewBytes = Int64(preview) << 20 }
        if [50_000, 100_000, 200_000].contains(entries) { limits.maximumEntries = entries }
        return limits
    }
}
