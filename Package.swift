// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RecordApp",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "RecordApp",
            path: "Sources/RecordApp",
            exclude: ["Info.plist", "RecordApp.entitlements"]
        )
    ]
)
