// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZTERouterBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ZTERouterCore", targets: ["ZTERouterCore"]),
        .executable(name: "ZTERouterBar", targets: ["ZTERouterBar"])
    ],
    targets: [
        .target(
            name: "ZTERouterCore",
            dependencies: []
        ),
        .executableTarget(
            name: "ZTERouterBar",
            dependencies: ["ZTERouterCore"]
        ),
        .testTarget(
            name: "ZTERouterCoreTests",
            dependencies: ["ZTERouterCore"]
        )
    ]
)
