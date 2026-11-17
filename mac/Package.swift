// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ProjetarTV",
    platforms: [.macOS(.v14)],
    targets: [
        // Declarações da API privada CGVirtualDisplay (CoreGraphics), a mesma usada por DeskPad/BetterDisplay.
        .target(name: "CGVirtualDisplayPrivate", path: "Sources/CGVirtualDisplayPrivate"),
        .executableTarget(
            name: "ProjetarTV",
            dependencies: ["CGVirtualDisplayPrivate"],
            path: "Sources/ProjetarTV",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("Network"),
            ]
        ),
    ]
)
