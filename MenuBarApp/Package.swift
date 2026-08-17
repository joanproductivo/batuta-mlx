// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BatutaMLX",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "BatutaMLX", path: "Sources/BatutaMLX")
    ]
)
