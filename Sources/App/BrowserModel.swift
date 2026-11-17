import Foundation
import SwiftUI
import UIKit
import OSLog

@MainActor
final class BrowserModel: ObservableObject {
    enum SortOrder: String, CaseIterable { case name, size, date }
    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
    @Published var directory = FileRepository.home { didSet { localItems = [] } }
    @Published private(set) var localItems: [LocalFileItem] = [] { didSet { rebuildNodes() } }
    @Published private(set) var snapshot: ArchiveSnapshot? { didSet { rebuildNodes() } }
    @Published var archivePath = "" { didSet { rebuildNodes() } }
    @Published var selectedIDs: Set<String> = []
    @Published var focusedNode: BrowserNode?
    @Published var previewURL: URL?
    @Published var isPreparingPreview = false
    @Published var search = "" { didSet { rebuildNodes() } }
    @Published var sort: SortOrder = .name { didSet { rebuildNodes() } }
    @Published var showHidden = false { didSet { rebuildNodes(); Task { await refresh() } } }
    @Published var pickerPurpose: DocumentPickerPurpose?
    @Published var showCreate = false
    @Published var showSettings = false
    @Published var showTasks = false
    @Published var showEncoding = false
    @Published var showPassword = false
    @Published var showNarrowPreview = false
    @Published var notice: Notice?
    @Published var progress: ArchiveProgress?
    @Published private(set) var isBusy = false
    @Published var busyTitle = ""
    @Published var lastResult: URL?
    @Published var password = ""
    @Published var encoding: FilenameEncoding = .automatic
    @Published private(set) var encodingSamples: [String] = []
    @Published var renameTarget: BrowserNode?
    @Published var renameText = ""
    @Published var deleteTargets: [BrowserNode] = []
    private var openedURLs: [URL] = []
    private var operation: Task<Void, Never>?
    private var job: JobControl?
    private var previewTask: Task<Void, Never>?
    private var previewJob: JobControl?
    private var generation = UUID()
    private var previewGeneration = UUID()
    private var refreshGeneration = UUID()
    private var pendingOpenURLs: [URL]?
    @Published private(set) var taskRecords: [TaskRecord] = []
    private var queuedWork: [(id: UUID, title: String, action: @MainActor (JobControl) async throws -> Void)] = []
    private var engine: LibarchiveEngine { LibarchiveEngine(limits: ArchivePreferences.limits) }

    @Published private(set) var nodes: [BrowserNode] = []
    private func rebuildNodes() {
        let values = snapshot.map { BrowserNode.children(of: archivePath, in: $0, showHidden: showHidden) } ?? localItems.map(BrowserNode.local)
        nodes = values.filter { search.isEmpty || $0.name.localizedStandardContains(search) }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            switch sort {
            case .name: return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            case .size: return $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size
            case .date: return $0.modified == $1.modified ? $0.name < $1.name : $0.modified > $1.modified
            }
        }
    }
    var selectedNodes: [BrowserNode] { nodes.filter { selectedIDs.contains($0.id) } }
    var title: String { snapshot == nil ? (directory == FileRepository.home ? text("app.files") : directory.lastPathComponent) : (archivePath.isEmpty ? openedURLs.first?.lastPathComponent ?? "" : (archivePath as NSString).lastPathComponent) }
    var canGoBack: Bool { snapshot != nil || directory != FileRepository.home }
    var hasArchiveSource: Bool { !openedURLs.isEmpty }

    func start() async {
        do { try FileRepository.prepare(); await refresh() } catch { report(error) }
    }
    func refresh() async {
        guard snapshot == nil else { return }
        let current = directory
        let token = UUID(); refreshGeneration = token
        do {
            let items = try await FileRepository.list(current, showHidden: showHidden)
            if directory == current, refreshGeneration == token { localItems = items; selectedIDs.formIntersection(Set(items.map { $0.url.path })) }
        } catch { if refreshGeneration == token { report(error) } }
    }
    func importFiles(_ urls: [URL], asVolumes: Bool = false) {
        importFiles(PickedDocuments(urls: urls), asVolumes: asVolumes)
    }
    func importFiles(_ selection: PickedDocuments, asVolumes: Bool = false) {
        guard !selection.urls.isEmpty else { return }
        DocumentPickerLog.logger.notice("Queuing selected files for import")
        perform(title: text("task.import")) { [self] control in
            defer { withExtendedLifetime(selection) {} }
            let results = try await FileRepository.importFiles(selection.urls, asVolumes: asVolumes, control: control)
            closeArchive()
            directory = FileRepository.home
            await refresh()
            if asVolumes {
                pendingOpenURLs = results.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if results.count == 1, let first = results.first, (try? LocalFileItem(url: first))?.isArchive == true {
                pendingOpenURLs = [first]
            }
        }
    }
    func open(_ node: BrowserNode, narrow: Bool) {
        guard node.isSafe, !isBusy else { return }
        if node.isDirectory {
            clearPreview()
            selectedIDs = []
            if let path = node.archivePath { archivePath = path }
            else if let url = node.localURL { directory = url; Task { await refresh() } }
        } else if let url = node.localURL, (try? LocalFileItem(url: url))?.isArchive == true {
            openArchive([url])
        } else {
            focus(node)
            if narrow { showNarrowPreview = true }
        }
    }
    func focus(_ node: BrowserNode) {
        clearPreview()
        focusedNode = node
        guard !node.isDirectory, node.isSafe else { return }
        if let url = node.localURL { previewURL = url; return }
        guard let snapshot else { return }
        let token = UUID(); previewGeneration = token
        let control = JobControl(); previewJob = control
        isPreparingPreview = true
        let password = password
        previewTask = Task {
            do {
                let stage = try await engine.extract(snapshot, selection: node.entryIDs, password: password, preview: true, control: control)
                guard previewGeneration == token else { ArchiveWorkspace.removeStage(containing: stage); return }
                if let path = node.archivePath { previewURL = try ExtractionPolicy.destination(root: stage, relative: path) }
                isPreparingPreview = false
            } catch is CancellationError { if previewGeneration == token { isPreparingPreview = false } }
            catch {
                if previewGeneration == token {
                    isPreparingPreview = false
                    report(error)
                }
            }
        }
    }
    func goBack() {
        guard !isBusy else { return }
        clearPreview(); selectedIDs = []; search = ""
        if snapshot != nil {
            if archivePath.isEmpty { closeArchive(); Task { await refresh() } }
            else { archivePath = (archivePath as NSString).deletingLastPathComponent }
        } else if directory != FileRepository.home {
            directory = directory.deletingLastPathComponent(); Task { await refresh() }
        }
    }
    func closeArchive() {
        clearPreview(); snapshot = nil; archivePath = ""; openedURLs = []; password = ""
        encoding = .automatic; selectedIDs = []; generation = UUID()
        encodingSamples = []
    }
    func openArchive(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if openedURLs != urls { password = ""; encoding = .automatic; snapshot = nil; archivePath = ""; selectedIDs = [] }
        clearPreview(); openedURLs = urls
        let currentGeneration = UUID(); generation = currentGeneration
        let selectedEncoding = encoding, selectedPassword = password
        perform(title: text("task.open")) { [self] control in
            let result = try await engine.list(urls: urls, encoding: selectedEncoding, password: selectedPassword, control: control)
            guard generation == currentGeneration else { return }
            snapshot = result; archivePath = ""; selectedIDs = []
        }
    }
    func reopen() { let urls = openedURLs; snapshot = nil; openArchive(urls) }
    func loadEncodingSamples(for candidate: FilenameEncoding) async {
        guard let url = openedURLs.first else { encodingSamples = []; return }
        let selected = candidate
        let samples = await Task.detached(priority: .userInitiated) {
            FilenameDetector.samples(for: url, encoding: selected)
        }.value
        if !Task.isCancelled, openedURLs.first == url { encodingSamples = samples }
    }
    func extractSelection(all: Bool = false) {
        guard let snapshot else { return }
        let selected = all || selectedIDs.isEmpty ? nil : Set(selectedNodes.flatMap(\.entryIDs))
        perform(title: text("task.extract")) { [self] control in
            let stage = try await engine.extract(snapshot, selection: selected, password: password, control: control)
            let stem = openedURLs.first?.deletingPathExtension().lastPathComponent ?? "Archive"
            do { lastResult = try await FileRepository.commit(stage, name: stem + " " + text("app.extracted"), directory: FileRepository.home) }
            catch { ArchiveWorkspace.removeStage(containing: stage); throw error }
            notice = Notice(title: text("task.done"), message: lastResult?.lastPathComponent ?? "")
        }
    }
    func create(name: String, format: ArchiveFormat, level: Int, password: String) {
        let urls = selectedNodes.compactMap(\.localURL)
        perform(title: text("task.create")) { [self] control in
            let staged = try await engine.create(sources: urls, name: name, format: format, level: level, password: password, control: control)
            do { lastResult = try await FileRepository.commit(staged, name: staged.lastPathComponent, directory: directory) }
            catch { ArchiveWorkspace.removeStage(containing: staged); throw error }
            await refresh()
        }
    }
    func repack(name: String, format: ArchiveFormat, level: Int, password newPassword: String) {
        guard let snapshot else { return }
        let selected = selectedIDs.isEmpty ? nil : Set(selectedNodes.flatMap(\.entryIDs))
        let readingPassword = password
        perform(title: text("task.repack")) { [self] control in
            let staged = try await engine.repack(snapshot, selection: selected, readingPassword: readingPassword,
                name: name, format: format, level: level, password: newPassword, control: control)
            do { lastResult = try await FileRepository.commit(staged, name: staged.lastPathComponent, directory: FileRepository.home) }
            catch { ArchiveWorkspace.removeStage(containing: staged); throw error }
            notice = Notice(title: text("task.done"), message: lastResult?.lastPathComponent ?? "")
        }
    }
    func exportResult(to selection: PickedDocuments) {
        guard let result = lastResult, let folder = selection.urls.first else { return }
        perform(title: text("task.export")) { [self] control in
            defer { withExtendedLifetime(selection) {} }
            let exported = try await FileRepository.export(result, to: folder, control: control)
            notice = Notice(title: text(exported.skipped ? "conflict.skipped" : "task.done"), message: exported.url.lastPathComponent)
        }
    }
    func rename() {
        guard let source = renameTarget?.localURL else { return }
        do { try FileRepository.rename(source, to: renameText); renameTarget = nil; Task { await refresh() } }
        catch { report(error) }
    }
    func deleteConfirmed() {
        let urls = deleteTargets.compactMap(\.localURL)
        deleteTargets = []; clearPreview()
        perform(title: text("task.delete")) { [self] _ in
            try await Task.detached {
                for url in urls { try FileManager.default.removeItem(at: url) }
            }.value
            await refresh()
        }
    }
    func cancel() { job?.cancel(); operation?.cancel() }
    func clearPreview() {
        previewGeneration = UUID(); previewJob?.cancel(); previewTask?.cancel()
        if let previewURL { ArchiveWorkspace.removeStage(containing: previewURL) }
        previewURL = nil; focusedNode = nil; isPreparingPreview = false
    }
    private func perform(title: String, action: @escaping @MainActor (JobControl) async throws -> Void) {
        let id = UUID()
        taskRecords.append(TaskRecord(id: id, title: title, state: .queued))
        queuedWork.append((id, title, action))
        resumeQueue()
    }
    func cancelTask(_ id: UUID) {
        if activeOperationID == id { cancel(); return }
        queuedWork.removeAll { $0.id == id }
        setTaskState(id, .cancelled)
    }
    func clearCompletedTasks() { taskRecords.removeAll { !$0.state.isPending } }
    private func setTaskState(_ id: UUID, _ state: TaskRecord.State, detail: String = "") {
        guard let index = taskRecords.firstIndex(where: { $0.id == id }) else { return }
        taskRecords[index].state = state; taskRecords[index].detail = detail
    }
    func resumeQueue() {
        guard !isBusy, !queuedWork.isEmpty, UIApplication.shared.applicationState == .active else { return }
        let work = queuedWork.removeFirst()
        let title = work.title, action = work.action
        isBusy = true; busyTitle = title; progress = nil
        let operationID = work.id
        activeOperationID = operationID
        setTaskState(operationID, .running)
        let control = JobControl { [weak self] progress in
            Task { @MainActor in
                if self?.activeOperationID == operationID {
                    self?.progress = progress
                    self?.backgroundLease?.update(progress)
                }
            }
        }
        job = control
        operation = Task {
            let lease = BackgroundLease(name: title) { control.cancel() }
            backgroundLease = lease
            var succeeded = false
            do { try await action(control); succeeded = true; setTaskState(operationID, .completed) }
            catch is CancellationError { setTaskState(operationID, .cancelled) }
            catch { setTaskState(operationID, .failed, detail: error.localizedDescription); report(error) }
            lease.end(success: succeeded); backgroundLease = nil
            isBusy = false; job = nil; progress = nil; activeOperationID = nil
            if let urls = pendingOpenURLs { pendingOpenURLs = nil; openArchive(urls) }
            if taskRecords.count > 50 {
                var removals = taskRecords.count - 50
                taskRecords.removeAll { record in
                    if removals > 0 && !record.state.isPending { removals -= 1; return true }
                    return false
                }
            }
            resumeQueue()
        }
    }
    private var backgroundLease: BackgroundLease?
    private var activeOperationID: UUID?
    private func report(_ error: Error) {
        if let failure = error as? ArchiveFailure, failure.reason == .password { showPassword = true }
        else if let failure = error as? ArchiveFailure, failure.reason == .encoding { showEncoding = true }
        else { notice = Notice(title: text("error.title"), message: error.localizedDescription) }
    }
    private func text(_ key: String) -> String { NSLocalizedString(key, comment: "") }
}
