// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OboeCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "OboeDomain", targets: ["OboeDomain"]),
        .library(name: "OboeInfrastructure", targets: ["OboeInfrastructure"]),
        .library(name: "OboeSharedCapture", targets: ["OboeSharedCapture"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/open-spaced-repetition/swift-fsrs.git",
            revision: "4fbaf20184d62f82a9f44f343337c61a2c5483e9"
        ),
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
        )
    ],
    targets: [
        .target(name: "OboeDomain"),
        .target(name: "OboeSharedCapture"),
        .target(
            name: "OboeInfrastructure",
            dependencies: [
                "OboeDomain",
                "OboeSharedCapture",
                .product(name: "FSRS", package: "swift-fsrs"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(
            name: "OboeDomainTests",
            dependencies: ["OboeDomain"]
        ),
        .testTarget(
            name: "OboeInfrastructureTests",
            dependencies: [
                "OboeInfrastructure",
                "OboeSharedCapture",
                .product(name: "GRDB", package: "GRDB.swift"),
                // S21：RetentionCurveMath vs 引擎 getRetrievability 的
                // 逐位对照断言需要直接构造 FSRS 实例。
                .product(name: "FSRS", package: "swift-fsrs")
            ],
            resources: [.copy("Fixtures")]
        )
    ]
)
