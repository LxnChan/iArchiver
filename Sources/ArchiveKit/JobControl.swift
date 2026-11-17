import Foundation

public final class JobControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastReport = Date.distantPast
    private var filename = ""
    private var baseBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    private var entryIndex = 0
    private var entryCount = 0
    private let observer: @Sendable (ArchiveProgress) -> Void

    public init(observer: @escaping @Sendable (ArchiveProgress) -> Void = { _ in }) { self.observer = observer }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func check() throws { if isCancelled { throw CancellationError() } }
    func configure(filename: String, baseBytes: Int64, totalBytes: Int64, index: Int, count: Int) {
        lock.lock()
        self.filename = filename; self.baseBytes = baseBytes; self.totalBytes = totalBytes
        entryIndex = index; entryCount = count
        lock.unlock()
        report(0, force: true)
    }
    func report(_ bytes: Int64, force: Bool = false) {
        lock.lock()
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= 0.1 else { lock.unlock(); return }
        lastReport = now
        let progress = ArchiveProgress(filename: filename, completedBytes: baseBytes + bytes,
            totalBytes: totalBytes, completedEntries: entryIndex, totalEntries: entryCount)
        lock.unlock()
        observer(progress)
    }
}

let archiveCancelCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
    guard let context else { return 0 }
    return Unmanaged<JobControl>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
}
let archiveProgressCallback: @convention(c) (Int64, UnsafeMutableRawPointer?) -> Void = { bytes, context in
    guard let context else { return }
    Unmanaged<JobControl>.fromOpaque(context).takeUnretainedValue().report(bytes)
}

