import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let capabilities = BuildCapabilities.current
    @AppStorage("expandedGiB") private var expandedGiB = 64
    @AppStorage("previewMiB") private var previewMiB = 256
    @AppStorage("maximumEntries") private var maximumEntries = 200_000
    @AppStorage("exportConflict") private var exportConflict = "rename"
    var body: some View {
        NavigationStack {
            List {
                Section("settings.application") {
                    LabeledContent("settings.version", value: "0.1.0 (1)")
                    LabeledContent("settings.edition", value: capabilities.isSideload ? "Sideload" : "App Store")
                    LabeledContent("settings.engine", value: BuildCapabilities.engineVersion)
                }
                Section("settings.formats") {
                    LabeledContent("settings.read", value: capabilities.read.map { $0.uppercased() }.joined(separator: ", "))
                    LabeledContent("settings.write", value: capabilities.write.map { $0.uppercased() }.joined(separator: ", "))
                    Text(capabilities.isSideload ? LocalizedStringKey("settings.compatibilitySide") : LocalizedStringKey("settings.compatibility")).font(.footnote).foregroundStyle(.secondary)
                }
                Section("settings.privacy") {
                    Label("settings.offline", systemImage: "network.slash")
                    Label("settings.noAccount", systemImage: "person.crop.circle.badge.checkmark")
                    Text("settings.privacyDescription").font(.footnote).foregroundStyle(.secondary)
                }
                Section("settings.limits") {
                    Picker("settings.expandedLimit", selection: $expandedGiB) {
                        ForEach([4, 16, 64], id: \.self) { Text("\($0) GiB").tag($0) }
                    }
                    Picker("settings.previewLimit", selection: $previewMiB) {
                        ForEach([64, 128, 256], id: \.self) { Text("\($0) MiB").tag($0) }
                    }
                    Picker("settings.entryLimit", selection: $maximumEntries) {
                        ForEach([50_000, 100_000, 200_000], id: \.self) { Text($0.formatted()).tag($0) }
                    }
                    Text("settings.limitHelp").font(.caption).foregroundStyle(.secondary)
                }
                Section("conflict.title") {
                    Picker("conflict.title", selection: $exportConflict) {
                        ForEach(FileRepository.ConflictBehavior.allCases) { behavior in Text(LocalizedStringKey(behavior.key)).tag(behavior.rawValue) }
                    }
                    Text("conflict.help").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink("settings.licenses") { LicenseView().navigationTitle("settings.licenses") }
                }
            }
            .navigationTitle("action.settings")
            .accessibilityIdentifier("settingsView")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("action.done") { dismiss() } } }
        }
    }
}

private struct LicenseView: View {
    var body: some View {
        ScrollView {
            Text(contents).font(.caption.monospaced()).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var contents: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "License notices unavailable." }
        if BuildCapabilities.current.isSideload, let extra = Bundle.main.url(forResource: "UnRARLicense", withExtension: "txt"),
           let license = try? String(contentsOf: extra, encoding: .utf8) { return text + "\n\n" + license }
        return text
    }
}

