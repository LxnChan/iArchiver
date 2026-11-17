import SwiftUI
import UIKit
import UniformTypeIdentifiers
import OSLog

enum DocumentPickerPurpose: String, Identifiable {
    case files, volumes, importFolder, exportFolder
    var id: String { rawValue }
    var selectsFolders: Bool { self == .importFolder || self == .exportFolder }
}

/// Acquire access in the picker callback, and keep it through dismissal and queuing.
/// The repository separately scopes its coordinated read/write operations.
final class PickedDocuments: @unchecked Sendable {
    let urls: [URL]
    private let scopedURLs: [URL]

    init(urls: [URL]) {
        self.urls = urls
        scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
    }

    deinit { for url in scopedURLs { url.stopAccessingSecurityScopedResource() } }
}

enum DocumentPickerLog {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "iArchiver", category: "DocumentPicker")
}

@MainActor
struct DocumentPicker: UIViewControllerRepresentable {
    let purpose: DocumentPickerPurpose
    let onSelection: (PickedDocuments) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Return provider URLs without a system import copy. The app performs its
        // cancellable, observable copy only after the sheet has finished closing.
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: purpose.selectsFolders ? [.folder] : [.item], asCopy: false)
        picker.allowsMultipleSelection = !purpose.selectsFolders
        picker.directoryURL = FileRepository.home
        picker.delegate = context.coordinator
        picker.view.accessibilityIdentifier = "documentPicker"
        DocumentPickerLog.logger.notice("Presenting document picker; copy disabled, folders: \(purpose.selectsFolders)")
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection, onCancel: onCancel) }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onSelection: (PickedDocuments) -> Void
        private let onCancel: () -> Void
        private var completed = false

        init(onSelection: @escaping (PickedDocuments) -> Void, onCancel: @escaping () -> Void) {
            self.onSelection = onSelection
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !completed else { return }
            completed = true
            DocumentPickerLog.logger.notice("Received document selection; count: \(urls.count)")
            if urls.isEmpty { onCancel() }
            else { onSelection(PickedDocuments(urls: urls)) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !completed else { return }
            completed = true
            DocumentPickerLog.logger.notice("Document selection cancelled")
            onCancel()
        }
    }
}
