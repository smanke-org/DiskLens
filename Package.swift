// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DiskLens",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "DiskLensKit"),
        .executableTarget(name: "DiskLens", dependencies: ["DiskLensKit"]),
        .testTarget(name: "DiskLensKitTests", dependencies: ["DiskLensKit"]),
    ]
)
