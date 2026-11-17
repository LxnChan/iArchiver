import SwiftUI

@main
@MainActor
struct IArchiverApp: App {
    @UIApplicationDelegateAdaptor(ArchiveAppDelegate.self) private var appDelegate
    @StateObject private var model = BrowserModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            BrowserView(model: model)
                .tint(Color.accentColor)
                .task { await model.start() }
                .onOpenURL { url in model.importFiles([url]) }
                .onChange(of: scenePhase) { _, phase in if phase == .active { model.resumeQueue() } }
        }
    }
}

