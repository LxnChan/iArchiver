import SwiftUI

struct TaskRecord: Identifiable {
    enum State: String {
        case queued, running, completed, failed, cancelled
        var key: String { "queue." + rawValue }
        var isPending: Bool { self == .queued || self == .running }
        var symbol: String {
            switch self {
            case .queued: return "clock"
            case .running: return "arrow.triangle.2.circlepath"
            case .completed: return "checkmark.circle"
            case .failed: return "exclamationmark.circle"
            case .cancelled: return "xmark.circle"
            }
        }
    }
    let id: UUID
    let title: String
    var state: State
    var detail = ""
}

struct TaskQueueView: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if model.taskRecords.isEmpty { ContentUnavailableView("queue.empty", systemImage: "checklist") }
                ForEach(model.taskRecords.reversed()) { record in
                    HStack {
                        Image(systemName: record.state.symbol).foregroundStyle(record.state == .failed ? Color.red : Color.accentColor)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.title)
                            Text(LocalizedStringKey(record.state.key)).font(.caption).foregroundStyle(.secondary)
                            if !record.detail.isEmpty { Text(record.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        Spacer()
                        if record.state.isPending {
                            Button("action.cancel") { model.cancelTask(record.id) }.font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("queue.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("queue.clear") { model.clearCompletedTasks() } }
                ToolbarItem(placement: .confirmationAction) { Button("action.done") { dismiss() } }
            }
        }
    }
}
