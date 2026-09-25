// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LTEStickView",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LTEStickView", path: "Sources/LTEStickView")
    ]
)
