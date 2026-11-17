import SwiftUI

struct CreateArchiveView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Archive"
    @State private var format = ArchiveFormat.zip
    @State private var level = 5.0
    @State private var encrypted = false
    @State private var password = ""
    @State private var confirmation = ""
    var isRepacking = false
    let create: (String, ArchiveFormat, Int, String) -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("create.archive") {
                    TextField("field.name", text: $name).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Picker("field.format", selection: $format) {
                        ForEach(ArchiveFormat.writable) { format in Text(format.title).tag(format) }
                    }
                    if format != .tar && format != .iso {
                        LabeledContent("field.compression", value: "\(Int(level))")
                        Slider(value: $level, in: 0...9, step: 1).accessibilityLabel("field.compression")
                    }
                }
                if format.supportsPasswordCreation {
                    Section("create.security") {
                        Toggle("field.encrypt", isOn: $encrypted)
                        if encrypted {
                            SecureField("field.password", text: $password).textContentType(.newPassword)
                            SecureField("field.confirmPassword", text: $confirmation).textContentType(.newPassword)
                            Text(format == .sevenZip ? LocalizedStringKey("create.sevenZipAesHint") : LocalizedStringKey("create.aesHint")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if format == .gzip { Text("create.gzipHint").font(.footnote).foregroundStyle(.secondary) }
                Text("create.originalsKept").font(.footnote).foregroundStyle(.secondary)
                if isRepacking { Text("create.repackHelp").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle(isRepacking ? LocalizedStringKey("action.repack") : LocalizedStringKey("action.compress"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.create") {
                        let secret = encrypted && format.supportsPasswordCreation ? password : ""
                        create(name.trimmingCharacters(in: .whitespacesAndNewlines), format, Int(level), secret)
                        password = ""; confirmation = ""; dismiss()
                    }.disabled(!valid)
                }
            }
            .onChange(of: format) { _, _ in password = ""; confirmation = ""; encrypted = false }
        }
    }
    private var valid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.contains("/") && (try? ExtractionPolicy.normalized(trimmed)) == trimmed
            && (!encrypted || (!password.isEmpty && password == confirmation))
    }
}

