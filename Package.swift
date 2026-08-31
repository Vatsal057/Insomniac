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
        // Pinned to the minor series that's actually resolved and tested, so a
        // future 2.x release can't be pulled in unreviewed on a clean checkout.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", .upToNextMinor(from: "2.4.0"))
    ],
    targets: [
        .executableTarget(
            name: "Insomniac",
            dependencies: ["KeyboardShortcuts"],
            // No linker flags: DisplayServices is a private framework and is
            // resolved at runtime via dlopen/dlsym in DisplayManager instead.
            // Hard-linking it made a missing framework a launch failure, and
            // `unsafeFlags` also blocks this package from being depended on.
            path: "Sources/Insomniac"
        )
    ]
)
