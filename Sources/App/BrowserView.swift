import SwiftUI
import OSLog

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    @State private var multiSelect = false
    @State private var previewVisible = true
    @State private var pendingSelection: (purpose: DocumentPickerPurpose, documents: PickedDocuments)?
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 720
            NavigationStack {
                VStack(spacing: 0) {
                    if let snapshot = model.snapshot { archiveBar(snapshot) }
                    GeometryReader { paneGeometry in
                        let frames = PaneLayout.avoidingOcclusions(
                            PaneLayout.frames(size: paneGeometry.size, showPreview: previewVisible, division: activeDivision(in: paneGeometry)),
                            regions: activeOcclusions(in: paneGeometry))
                        ZStack(alignment: .topLeading) {
                            Color.secondary.opacity(0.15)
                            if let preview = frames.preview {
                                PreviewPane(node: model.focusedNode, url: model.previewURL, loading: model.isPreparingPreview)
                                    .accessibilityElement(children: .contain)
                                    .accessibilityIdentifier("previewPane")
                                    .background(.background.secondary)
                                    .frame(width: preview.width, height: preview.height)
                                    .position(x: preview.midX, y: preview.midY)
                            }
                            fileList(wide: frames.preview != nil)
                                .background(.background)
                                .frame(width: frames.files.width, height: frames.files.height)
                                .position(x: frames.files.midX, y: frames.files.midY)
                        }
                    }
                    if model.isBusy { TaskProgressView(title: model.busyTitle, progress: model.progress, cancel: model.cancel) }
                    if let result = model.lastResult { resultBar(result) }
                }
                .navigationTitle(model.title)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $model.search, prompt: Text("action.search"))
                .toolbar { toolbar(wide: wide) }
                .safeAreaInset(edge: .bottom) { actionBar }
                .onChange(of: wide) { _, isWide in if isWide { model.showNarrowPreview = false } }
                .sheet(isPresented: $model.showCreate) {
                    CreateArchiveView(isRepacking: model.snapshot != nil) { name, format, level, password in
                        if model.snapshot != nil { model.repack(name: name, format: format, level: level, password: password) }
                        else { model.create(name: name, format: format, level: level, password: password) }
                    }
                }
                .sheet(isPresented: $model.showEncoding) { encodingSheet }
                .sheet(isPresented: $model.showPassword) { passwordSheet }
                .sheet(isPresented: $model.showSettings) { SettingsView() }
                .sheet(isPresented: $model.showTasks) { TaskQueueView(model: model) }
                .sheet(isPresented: $model.showNarrowPreview) {
                    NavigationStack {
                        PreviewPane(node: model.focusedNode, url: model.previewURL, loading: model.isPreparingPreview)
                            .navigationTitle(model.focusedNode?.name ?? "")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("action.done") { model.showNarrowPreview = false } } }
                    }
                }
                .alert(item: $model.notice) { notice in Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("action.ok"))) }
                .alert("action.rename", isPresented: Binding(get: { model.renameTarget != nil }, set: { if !$0 { model.renameTarget = nil } })) {
                    TextField("field.name", text: $model.renameText)
                    Button("action.cancel", role: .cancel) { model.renameTarget = nil }
                    Button("action.save") { model.rename() }
                }
                .confirmationDialog("delete.confirm", isPresented: Binding(get: { !model.deleteTargets.isEmpty }, set: { if !$0 { model.deleteTargets = [] } }), titleVisibility: .visible) {
                    Button("action.delete", role: .destructive) { model.deleteConfirmed() }
                }
                .sheet(item: $model.pickerPurpose, onDismiss: finishPicking) { purpose in
                    DocumentPicker(purpose: purpose) { documents in
                        pendingSelection = (purpose, documents)
                        model.pickerPurpose = nil
                    } onCancel: {
                        pendingSelection = nil
                        model.pickerPurpose = nil
                    }
                }
            }
        }
    }

    private func activeDivision(in geometry: GeometryProxy) -> CGRect? {
        if #available(iOS 27.1, *) {
            return geometry.reservedRegions(kind: .division).map(\.frame).first
        }
        return nil
    }
    private func activeOcclusions(in geometry: GeometryProxy) -> [CGRect] {
        if #available(iOS 27.1, *) { return geometry.reservedRegions(kind: .occlusion).map(\.frame) }
        return []
    }

    private func fileList(wide: Bool) -> some View {
        List {
            if model.nodes.isEmpty && !model.isBusy {
                ContentUnavailableView(LocalizedStringKey(model.search.isEmpty ? "empty.title" : "empty.search"), systemImage: "tray", description: Text(LocalizedStringKey(model.search.isEmpty ? "empty.description" : "empty.search.description")))
                    .listRowSeparator(.hidden)
            }
            ForEach(model.nodes) { node in
                Button {
                    if multiSelect {
                        if model.selectedIDs.contains(node.id) { model.selectedIDs.remove(node.id) }
                        else { model.selectedIDs.insert(node.id) }
                        if wide { model.focus(node) }
                    } else { model.open(node, narrow: !wide) }
                } label: {
                    FileRow(node: node, selecting: multiSelect, selected: model.selectedIDs.contains(node.id))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!node.isSafe || model.isBusy)
                .listRowBackground(model.focusedNode?.id == node.id ? Color.accentColor.opacity(0.09) : Color.clear)
                .contextMenu {
                    if node.isDirectory { Button("action.open", systemImage: "folder") { model.open(node, narrow: !wide) } }
                    else {
                        Button("action.preview", systemImage: "eye") { model.focus(node); if !wide { model.showNarrowPreview = true } }
                        if let url = node.localURL { Button("action.openArchive", systemImage: "archivebox") { model.openArchive([url]) } }
                    }
                    if let url = node.localURL {
                        ShareLink(item: url) { Label("action.share", systemImage: "square.and.arrow.up") }
                        Button("action.rename", systemImage: "pencil") { model.renameText = node.name; model.renameTarget = node }
                        Button("action.delete", systemImage: "trash", role: .destructive) { model.deleteTargets = [node] }
                    }
                }
                .accessibilityLabel(node.name)
                .accessibilityValue(node.isDirectory ? NSLocalizedString("file.folder", comment: "") : ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file))
            }
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
        .accessibilityIdentifier("fileList")
    }

    @ToolbarContentBuilder
    private func toolbar(wide: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if model.canGoBack {
                Button(action: model.goBack) { Label("action.back", systemImage: "chevron.backward") }.disabled(model.isBusy)
                    .keyboardShortcut(.leftArrow, modifiers: .command)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { model.showTasks = true } label: { Label("queue.title", systemImage: "checklist") }
            if wide {
                Button { previewVisible.toggle() } label: { Label("action.togglePreview", systemImage: "sidebar.left") }
            }
            Button { multiSelect.toggle(); model.selectedIDs = [] } label: {
                Label(LocalizedStringKey(multiSelect ? "action.done" : "action.select"), systemImage: multiSelect ? "checkmark.circle.fill" : "checkmark.circle")
            }.disabled(model.isBusy)
            Menu {
                Button("action.import", systemImage: "square.and.arrow.down") { model.pickerPurpose = .files }
                Button("action.importFolder", systemImage: "folder.badge.plus") { model.pickerPurpose = .importFolder }
                Button("action.volumes", systemImage: "square.stack.3d.up") { model.pickerPurpose = .volumes }
                if model.hasArchiveSource {
                    Button("encoding.title", systemImage: "character.bubble") { model.showEncoding = true }
                    Button("field.password", systemImage: "key") { model.showPassword = true }
                }
                if multiSelect { Button("action.selectAll", systemImage: "checkmark.circle") { model.selectedIDs = Set(model.nodes.filter(\.isSafe).map(\.id)) } }
                Picker("action.sort", selection: $model.sort) {
                    Text("sort.name").tag(BrowserModel.SortOrder.name)
                    Text("sort.size").tag(BrowserModel.SortOrder.size)
                    Text("sort.date").tag(BrowserModel.SortOrder.date)
                }
                Toggle("action.hidden", isOn: $model.showHidden)
                Button("action.settings", systemImage: "gearshape") { model.showSettings = true }
                    .accessibilityIdentifier("openSettings")
            } label: { Label("action.more", systemImage: "ellipsis.circle") }
                .accessibilityIdentifier("moreActions")
                .disabled(model.isBusy)
        }
    }

    private var actionBar: some View {
        HStack {
            Button { model.pickerPurpose = .files } label: { Label("action.import", systemImage: "plus") }
                .keyboardShortcut("o", modifiers: .command)
                .accessibilityIdentifier("importFiles")
            Spacer()
            if model.snapshot != nil {
                Button { model.showCreate = true } label: { Label("action.repack", systemImage: "arrow.triangle.2.circlepath") }
                Button { model.extractSelection() } label: { Label(LocalizedStringKey(model.selectedIDs.isEmpty ? "action.extractAll" : "action.extract"), systemImage: "arrow.up.bin") }
                    .buttonStyle(.borderedProminent)
            } else {
                Button { model.showCreate = true } label: { Label("action.compress", systemImage: "archivebox") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedIDs.isEmpty)
            }
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(.bar)
        .disabled(model.isBusy)
    }
    private func archiveBar(_ snapshot: ArchiveSnapshot) -> some View {
        HStack {
            Image(systemName: "archivebox").foregroundStyle(.tint)
            Text(snapshot.formatName).font(.caption).lineLimit(1)
            Spacer()
            Button { model.showEncoding = true } label: { Label(snapshot.encoding.title, systemImage: "character.bubble") }.font(.caption)
            Button { model.showPassword = true } label: { Image(systemName: "key") }.accessibilityLabel("field.password")
        }
        .padding(.horizontal).padding(.vertical, 8).background(.background.secondary)
        .disabled(model.isBusy)
        .accessibilityIdentifier("archiveSummary")
    }
    private func resultBar(_ url: URL) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(url.lastPathComponent).font(.caption).lineLimit(1)
            Spacer()
            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("action.share")
            Button { model.pickerPurpose = .exportFolder } label: { Image(systemName: "folder.badge.plus") }.accessibilityLabel("action.export")
            Button { model.lastResult = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("action.dismiss")
        }.padding(12).background(.background.secondary)
    }
    private var encodingSheet: some View { ArchiveEncodingView(model: model) }
    private var passwordSheet: some View { ArchivePasswordView(model: model) }
    private func finishPicking() {
        DocumentPickerLog.logger.notice("Document picker dismissed")
        guard let selection = pendingSelection else { return }
        pendingSelection = nil
        switch selection.purpose {
        case .files, .importFolder: model.importFiles(selection.documents)
        case .volumes: model.importFiles(selection.documents, asVolumes: true)
        case .exportFolder: model.exportResult(to: selection.documents)
        }
    }
}

struct FileRow: View {
    let node: BrowserNode
    let selecting: Bool
    let selected: Bool
    var body: some View {
        HStack(spacing: 12) {
            if selecting { Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : .secondary) }
            Image(systemName: node.symbol)
                .font(.title2).foregroundStyle(node.isDirectory ? Color.accentColor : .secondary).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(node.name).font(.body).lineLimit(2)
                    if node.isEncrypted { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                }
                HStack(spacing: 8) {
                    if !node.isDirectory { Text(ByteCountFormatter.string(fromByteCount: max(0, node.size), countStyle: .file)) }
                    if !node.isSafe { Text("file.blocked") }
                    else { Text(node.modified, style: .date) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if node.isDirectory { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
        }.padding(.vertical, 6)
    }
}

struct TaskProgressView: View {
    let title: String
    let progress: ArchiveProgress?
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.bold())
                Spacer()
                Button("action.cancel", action: cancel).font(.subheadline)
            }
            if let fraction = progress?.fraction { ProgressView(value: fraction) }
            else { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
            if let progress {
                Text(progress.filename).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                if progress.totalBytes > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }.padding().background(.regularMaterial)
        .accessibilityIdentifier("taskProgress")
    }
}
