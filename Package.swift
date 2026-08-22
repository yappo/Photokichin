// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Photokichin",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Photokichin", targets: ["PhotokichinApp"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PhotokichinDomain"
        ),
        .target(
            name: "PhotokichinApplication",
            dependencies: ["PhotokichinDomain"]
        ),
        .target(
            name: "PhotokichinInfrastructure",
            dependencies: ["PhotokichinApplication", "PhotokichinDomain"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("ImageCaptureCore"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "PhotokichinPresentation",
            dependencies: ["PhotokichinApplication", "PhotokichinDomain"],
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .executableTarget(
            name: "PhotokichinApp",
            dependencies: [
                "PhotokichinPresentation",
                "PhotokichinApplication",
                "PhotokichinInfrastructure"
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "PhotokichinDomainTests",
            dependencies: ["PhotokichinDomain"]
        ),
        .testTarget(
            name: "PhotokichinApplicationTests",
            dependencies: ["PhotokichinApplication", "PhotokichinDomain"]
        ),
        .testTarget(
            name: "PhotokichinInfrastructureTests",
            dependencies: ["PhotokichinInfrastructure", "PhotokichinApplication", "PhotokichinDomain"]
        ),
        .testTarget(
            name: "PhotokichinPresentationTests",
            dependencies: [
                "PhotokichinPresentation",
                "PhotokichinInfrastructure",
                "PhotokichinApplication",
                "PhotokichinDomain"
            ]
        ),
        .testTarget(
            name: "PhotokichinHardwareTests",
            dependencies: ["PhotokichinInfrastructure", "PhotokichinApplication", "PhotokichinDomain"]
        )
    ],
    swiftLanguageModes: [.v6]
)
