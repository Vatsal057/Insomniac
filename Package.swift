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
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Insomniac",
            dependencies: ["KeyboardShortcuts"],
            path: "Sources/Insomniac",
            linkerSettings: [
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "DisplayServices"])
            ]
        )
    ]
)
