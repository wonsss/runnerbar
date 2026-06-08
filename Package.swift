// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "RunnerBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "RunnerBar", targets: ["RunnerBar"])
    ],
    targets: [
        .executableTarget(
            name: "RunnerBar",
            path: "Sources/RunnerBar"
        )
    ]
)
