import SwiftUI

struct ArchiveEncodingView: View {
    @ObservedObject var model: BrowserModel
    @State private var draft: FilenameEncoding = .automatic
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("encoding.help").font(.subheadline).foregroundStyle(.secondary) }
                Picker("encoding.title", selection: $draft) {
                    ForEach(FilenameEncoding.allCases) { encoding in Text(encoding.title).tag(encoding) }
                }.pickerStyle(.inline)
                if model.snapshot?.encodingWasInferred == true { Text("encoding.inferred").font(.footnote).foregroundStyle(.secondary) }
                if !model.encodingSamples.isEmpty {
                    Section("encoding.samples") {
                        ForEach(Array(model.encodingSamples.enumerated()), id: \.offset) { _, name in
                            Text(name).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            .onAppear { draft = model.encoding }
            .task(id: draft) { await model.loadEncodingSamples(for: draft) }
            .navigationTitle("encoding.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { model.showEncoding = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.apply") { model.encoding = draft; model.showEncoding = false; model.reopen() }
                }
            }
        }.presentationDetents([.large])
    }
}

struct ArchivePasswordView: View {
    @ObservedObject var model: BrowserModel
    @State private var draft = ""
    var body: some View {
        NavigationStack {
            Form {
                SecureField("field.password", text: $draft).textContentType(.password).autocorrectionDisabled()
                Text("password.help").font(.footnote).foregroundStyle(.secondary)
            }
            .onAppear { draft = model.password }
            .onDisappear { draft = "" }
            .navigationTitle("field.password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { model.showPassword = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.open") { model.password = draft; draft = ""; model.showPassword = false; model.reopen() }
                }
            }
        }.presentationDetents([.medium, .large])
    }
}
