import Foundation

/// Window-local geometry, with no screen, device model, or orientation assumptions.
public enum PaneLayout {
    public struct Frames: Equatable {
        public let preview: CGRect?
        public let files: CGRect
    }
    public static func frames(size: CGSize, showPreview: Bool, division: CGRect? = nil) -> Frames {
        let bounds = CGRect(origin: .zero, size: size)
        guard showPreview, size.width >= 720 else { return Frames(preview: nil, files: bounds) }
        if let fold = division?.intersection(bounds), !fold.isNull {
            if fold.height >= size.height * 0.6, fold.minX >= 240, size.width - fold.maxX >= 280 {
                return Frames(preview: CGRect(x: 0, y: 0, width: fold.minX, height: size.height),
                              files: CGRect(x: fold.maxX, y: 0, width: size.width - fold.maxX, height: size.height))
            }
            // Tabletop pose: keep both panels reachable on opposite sides of the horizontal fold.
            if fold.width >= size.width * 0.6, fold.minY >= 160, size.height - fold.maxY >= 180 {
                return Frames(preview: CGRect(x: 0, y: 0, width: size.width, height: fold.minY),
                              files: CGRect(x: 0, y: fold.maxY, width: size.width, height: size.height - fold.maxY))
            }
        }
        let previewWidth = min(420, max(260, size.width * 0.36))
        return Frames(preview: CGRect(x: 0, y: 0, width: previewWidth, height: size.height),
                      files: CGRect(x: previewWidth + 1, y: 0, width: size.width - previewWidth - 1, height: size.height))
    }
    public static func avoidingOcclusions(_ frames: Frames, regions: [CGRect]) -> Frames {
        func safe(_ original: CGRect) -> CGRect {
            var current = original
            for region in regions {
                let overlap = current.intersection(region.insetBy(dx: -8, dy: -8))
                guard !overlap.isNull, !overlap.isEmpty else { continue }
                let options = [
                    CGRect(x: current.minX, y: current.minY, width: max(0, overlap.minX - current.minX), height: current.height),
                    CGRect(x: overlap.maxX, y: current.minY, width: max(0, current.maxX - overlap.maxX), height: current.height),
                    CGRect(x: current.minX, y: current.minY, width: current.width, height: max(0, overlap.minY - current.minY)),
                    CGRect(x: current.minX, y: overlap.maxY, width: current.width, height: max(0, current.maxY - overlap.maxY))
                ]
                if let largest = options.filter({ $0.width >= 120 && $0.height >= 120 }).max(by: { $0.width * $0.height < $1.width * $1.height }) {
                    current = largest
                }
            }
            return current
        }
        return Frames(preview: frames.preview.map(safe), files: safe(frames.files))
    }
}
