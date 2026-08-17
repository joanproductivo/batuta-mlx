// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Batuta",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Batuta", path: "Sources/Batuta")
    ]
)
