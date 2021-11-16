// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "KSHLSPlayer",
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "KSHLSPlayer",
            targets: ["KSHLSPlayer"])
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "KSHLSPlayer",
            dependencies: [
                .product(name: "Swifter", package: "swifter")
            ],
            path: "Sources"),
        .testTarget(
            name: "KSHLSPlayerTests",
            dependencies: ["KSHLSPlayer",
                           .product(name: "Swifter", package: "swifter")
                          ]),
    ]
)
