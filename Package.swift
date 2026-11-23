// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KirkLogging",
    platforms: [.macOS(.v14)],
    products: [.library(name: "KirkLogging", targets: ["KirkLogging"])],
    dependencies: [
        .package(url: "https://github.com/CocoaLumberjack/CocoaLumberjack.git", exact: "3.8.5"),
    ],
    targets: [
        .target(name: "KirkLogging", dependencies: [
            .product(name: "CocoaLumberjack", package: "CocoaLumberjack"),
        ]),
        .testTarget(name: "KirkLoggingTests", dependencies: ["KirkLogging"]),
    ],
    swiftLanguageModes: [.v5]
)
