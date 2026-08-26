// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StripRotate",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StripRotate", targets: ["StripRotate"])
    ],
    targets: [
        .target(
            name: "PrivateDisplay",
            path: "Sources/PrivateDisplay",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "StripRotate",
            dependencies: ["PrivateDisplay"],
            path: "Sources/StripRotate",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
