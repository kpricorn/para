// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Para",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Para",
            path: "Sources/Para",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        )
    ]
)
