// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CSSH",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "CSSH", targets: ["CSSH"]),
    ],
    targets: [
        .binaryTarget(name: "CSSH", path: "CSSH.xcframework"),
    ]
)
