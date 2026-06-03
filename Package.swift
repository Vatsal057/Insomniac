// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Insomniac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Insomniac", targets: ["Insomniac"])
    ],
    targets: [
        .executableTarget(
            name: "Insomniac",
            path: "Sources/Insomniac",
            linkerSettings: [
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "DisplayServices"])
            ]
        )
    ]
)
