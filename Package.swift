// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OmniTrans",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OmniTrans",
            path: "Sources/OmniTrans"
        )
    ]
)
