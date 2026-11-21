// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The alpha-only debug tools (Debug menu, Sources/TrainCull/AlphaDebug): built in unless the
// build is made with TC_ALPHA_DEBUG=0. To remove them for good: delete that folder and
// Tests/TrainCullTests/AlphaDebugTests.swift, these lines, and the one `.commands` line marked
// in TrainCullApp.swift.
let alphaDebug = ProcessInfo.processInfo.environment["TC_ALPHA_DEBUG"] != "0"
let appSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)] + (alphaDebug ? [.define("TC_ALPHA_DEBUG")] : [])

// TraincullCore: no UI, Foundation only. It builds and is tested on Linux as well as macOS.
// TrainCull: the Mac app. It exists only when the package is built on a Mac.
var targets: [Target] = [
    .target(
        name: "TraincullCore",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // Writes the made-up DNG the automated build's launch check opens.
    .executableTarget(
        name: "MakeDng",
        dependencies: ["TraincullCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "TraincullCoreTests",
        dependencies: ["TraincullCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]
var products: [Product] = [.library(name: "TraincullCore", targets: ["TraincullCore"])]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "TrainCull",
        dependencies: ["TraincullCore"],
        swiftSettings: appSettings
    )
)
products.append(.executable(name: "TrainCull", targets: ["TrainCull"]))
// Checks that need Apple's imaging frameworks, such as the TIFF export opening in Apple's reader.
targets.append(
    .testTarget(
        name: "TrainCullTests",
        dependencies: ["TrainCull", "TraincullCore"],
        swiftSettings: appSettings
    )
)
#endif

let package = Package(
    name: "TrainCull",
    platforms: [.macOS(.v15)],
    products: products,
    targets: targets
)
