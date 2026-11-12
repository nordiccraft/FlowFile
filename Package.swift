// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FlowFile",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "FlowFile", targets: ["FlowFile"])
    ],
    targets: [
        .executableTarget(
            name: "FlowFile",
            path: "Sources/FlowFile",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Network"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO")
            ]
        ),
        .testTarget(
            name: "FlowFileTests",
            dependencies: ["FlowFile"],
            path: "Tests/FlowFileTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
