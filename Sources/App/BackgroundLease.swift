import UIKit
import BackgroundTasks

@MainActor
final class ArchiveAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundTaskManager.register()
        return true
    }
}

/// An active user operation, backed by continued processing when granted,
/// otherwise a finite UIApplication grace period. No promise of unlimited execution.
@MainActor
final class BackgroundLease {
    private var finiteIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var continuedTask: AnyObject?
    fileprivate var requestIdentifier: String?
    private let expiration: @Sendable () -> Void
    private var finished = false

    init(name: String, expiration: @escaping @Sendable () -> Void) {
        self.expiration = expiration
        finiteIdentifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                guard let self, self.continuedTask == nil else { return }
                expiration(); self.endFinite()
            }
        }
        if #available(iOS 26.0, *), UIApplication.shared.applicationState == .active {
            BackgroundTaskManager.submit(self, title: name)
        }
    }
    @available(iOS 26.0, *)
    fileprivate func attach(_ task: BGContinuedProcessingTask) {
        guard !finished else { task.setTaskCompleted(success: false); return }
        continuedTask = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expiration() }
        }
        task.progress.totalUnitCount = -1
        endFinite()
    }
    func update(_ progress: ArchiveProgress) {
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            if progress.totalBytes > 0 {
                task.progress.totalUnitCount = progress.totalBytes
                task.progress.completedUnitCount = min(progress.completedBytes, progress.totalBytes)
            } else if progress.totalEntries > 0 {
                task.progress.totalUnitCount = Int64(progress.totalEntries)
                task.progress.completedUnitCount = Int64(progress.completedEntries)
            }
        }
    }
    func end(success: Bool) {
        guard !finished else { return }
        finished = true
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            if success { task.progress.totalUnitCount = 1; task.progress.completedUnitCount = 1 }
            task.setTaskCompleted(success: success)
        }
        continuedTask = nil
        BackgroundTaskManager.remove(requestIdentifier)
        endFinite()
    }
    private func endFinite() {
        if finiteIdentifier != .invalid {
            UIApplication.shared.endBackgroundTask(finiteIdentifier)
            finiteIdentifier = .invalid
        }
    }
}

@MainActor
private enum BackgroundTaskManager {
    private static var leases: [String: BackgroundLease] = [:]
    private static var registered = false
    private static var prefix: String { (Bundle.main.bundleIdentifier ?? "local.iarchiver") + ".archive." }
    static func register() {
        if #available(iOS 26.0, *), !registered {
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: prefix + "*", using: .main) { task in
                Task { @MainActor in
                    guard let continued = task as? BGContinuedProcessingTask,
                          let lease = leases[task.identifier] else { task.setTaskCompleted(success: false); return }
                    lease.attach(continued)
                }
            }
        }
    }
    @available(iOS 26.0, *)
    static func submit(_ lease: BackgroundLease, title: String) {
        guard registered else { return }
        let id = prefix + UUID().uuidString
        leases[id] = lease; lease.requestIdentifier = id
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: title,
            subtitle: NSLocalizedString("background.subtitle", comment: ""))
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) }
        catch { leases.removeValue(forKey: id); lease.requestIdentifier = nil }
    }
    static func remove(_ id: String?) {
        guard let id else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
        leases.removeValue(forKey: id)
    }
}
