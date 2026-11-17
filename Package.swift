// swift-tools-version: 5.10
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let native = root + "/Build/native/host/appstore"
let package = Package(
    name: "IArchiverKit",
    platforms: [.macOS(.v14), .iOS("18.0")],
    products: [.library(name: "IArchiverKit", targets: ["IArchiverKit"])],
    targets: [
        .systemLibrary(name: "ArchiveCore", path: "PackageSupport/ArchiveCore"),
        .target(name: "IArchiverKit", dependencies: ["ArchiveCore"], path: "Sources/ArchiveKit",
            linkerSettings: [.unsafeFlags(["-L", native, "-Xlinker", "-rpath", "-Xlinker", native])]),
        .testTarget(name: "IArchiverKitTests", dependencies: ["IArchiverKit"], path: "Tests/ArchiveKitTests",
                    resources: [.copy("Fixtures")])
    ]
)
