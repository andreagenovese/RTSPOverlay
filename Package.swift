// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RTSPOverlay",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "RTSPOverlay", path: "Sources/RTSPOverlay")
    ]
)
