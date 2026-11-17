import SwiftUI
import UIKit
import ImageIO
import QuickLook
import AVFoundation
import UniformTypeIdentifiers

struct PreviewPane: View {
    let node: BrowserNode?
    let url: URL?
    let loading: Bool
    var body: some View {
        VStack(spacing: 0) {
            if loading {
                Spacer()
                ProgressView("preview.preparing").padding()
                Text("preview.solidHint").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                Spacer()
            } else if let url {
                let type = UTType(filenameExtension: url.pathExtension)
                if type?.conforms(to: .image) == true { ImagePreview(url: url).id(url) }
                else if type?.conforms(to: .audio) == true { AudioPreview(url: url).id(url) }
                else { QuickLookPreview(url: url).id(url) }
            } else if let node {
                ContentUnavailableView {
                    Label(node.name, systemImage: node.symbol)
                } description: {
                    Text(node.isDirectory ? LocalizedStringKey("preview.folder") : LocalizedStringKey("preview.unavailable"))
                }
            } else {
                ContentUnavailableView("preview.title", systemImage: "doc.viewfinder", description: Text("preview.description"))
            }
            if let node {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text(node.name).font(.subheadline.weight(.medium)).lineLimit(2).textSelection(.enabled)
                    HStack {
                        if !node.isDirectory { Text(ByteCountFormatter.string(fromByteCount: max(0, node.size), countStyle: .file)) }
                        Spacer()
                        if let url { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("action.share") }
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ImagePreview: View {
    let url: URL
    @State private var image: UIImage?
    @State private var failed = false
    @State private var scale = 1.0
    var body: some View {
        VStack(spacing: 0) {
            if let image {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(width: geometry.size.width * scale, height: geometry.size.height * scale)
                            .accessibilityLabel(url.lastPathComponent)
                            .onTapGesture(count: 2) { withAnimation { scale = scale == 1 ? 2 : 1 } }
                    }
                }
                HStack {
                    Button { scale = max(1, scale - 0.5) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("preview.zoomOut")
                    Slider(value: $scale, in: 1...6).accessibilityLabel("preview.zoom")
                    Button { scale = min(6, scale + 0.5) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("preview.zoomIn")
                }.padding()
            } else if failed {
                ContentUnavailableView("preview.unavailable", systemImage: "photo.badge.exclamationmark")
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: url) {
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            self.image = image.map { UIImage(cgImage: $0) }
            failed = image == nil
        }
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url { context.coordinator.url = url; controller.reloadData() }
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

@MainActor
private final class AudioPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var failed = false
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var generation = UUID()
    func load(_ url: URL) async {
        stop()
        let token = UUID(); generation = token
        failed = false; duration = 0; position = 0
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        do {
            guard try await item.asset.load(.isPlayable) else { failed = true; return }
            let duration = try await item.asset.load(.duration).seconds
            guard !Task.isCancelled, generation == token else { return }
            self.duration = duration.isFinite ? max(0, duration) : 0
        } catch { if generation == token { failed = true }; return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.position = time.seconds.isFinite ? time.seconds : 0 }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isPlaying = false; self?.seek(0) }
        }
    }
    func toggle() {
        if isPlaying { pause() }
        else {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                player.play(); isPlaying = true
            } catch { failed = true }
        }
    }
    func pause() { player.pause(); isPlaying = false }
    func seek(_ seconds: Double) { player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600)); position = max(0, seconds) }
    func stop() {
        generation = UUID()
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        player.replaceCurrentItem(with: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}

private struct AudioPreview: View {
    let url: URL
    @StateObject private var audio = AudioPlayer()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform").font(.system(size: 72, weight: .light)).foregroundStyle(.tint).accessibilityHidden(true)
            if audio.failed { Text("preview.audioUnsupported").foregroundStyle(.secondary) }
            Button(action: audio.toggle) {
                Image(systemName: audio.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 56))
            }.accessibilityLabel(audio.isPlaying ? Text("preview.pause") : Text("preview.play"))
                .disabled(audio.failed)
            VStack {
                Slider(value: Binding(get: { min(audio.position, max(audio.duration, 1)) }, set: audio.seek), in: 0...max(audio.duration, 1))
                    .disabled(audio.duration <= 0).accessibilityLabel("preview.position")
                HStack { Text(time(audio.position)); Spacer(); Text(time(audio.duration)) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(24)
        .task(id: url) { await audio.load(url) }
        .onDisappear { audio.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { audio.pause() } }
    }
    private func time(_ value: Double) -> String {
        let seconds = value.isFinite ? max(0, Int(value)) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

