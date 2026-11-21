// swift-tools-version: 6.0
import PackageDescription

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
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
)
products.append(.executable(name: "TrainCull", targets: ["TrainCull"]))
// Checks that need Apple's imaging frameworks, such as the TIFF export opening in Apple's reader.
targets.append(
    .testTarget(
        name: "TrainCullTests",
        dependencies: ["TrainCull", "TraincullCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
)
#endif

let package = Package(
    name: "TrainCull",
    platforms: [.macOS(.v15)],
    products: products,
    targets: targets
)
