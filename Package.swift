// swift-tools-version:5.9
import PackageDescription
import Foundation

// The App Store edition must not contain Sparkle at all. build_app.sh sets
// MUSECUBE_EDITION=appstore for that build, which drops the dependency entirely.
let isAppStore = ProcessInfo.processInfo.environment["MUSECUBE_EDITION"] == "appstore"

let package = Package(
    name: "Musecube",
    platforms: [.macOS(.v14)],
    dependencies: isAppStore ? [] : [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Musecube",
            dependencies: isAppStore ? [] : [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Musecube",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("Carbon"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
