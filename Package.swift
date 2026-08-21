// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "swift-tangled",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "tng", targets: ["tng"])
  ],
  traits: [
    .trait(
      name: "KeychainIntegrationTests",
      description: "Run integration tests against the macOS login Keychain"
    ),
    .default(enabledTraits: ["KeychainIntegrationTests"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/nnabeyang/swift-atproto.git",
      exact: "0.43.2"),
    .package(url: "https://github.com/germ-network/oauth4swift.git", exact: "0.6.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", "1.8.2" ..< "2.0.0"),
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    .package(
      url: "https://github.com/germ-network/GermConvenience.git",
      .upToNextMinor(from: "0.3.0")),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-http-types.git", from: "1.5.1"),
    .package(url: "https://github.com/steipete/Swiftdansi.git", exact: "0.3.0"),
    .package(
      url: "https://github.com/hummingbird-project/swift-websocket.git",
      exact: "1.6.1"
    ),
  ],
  targets: [
    .systemLibrary(
      name: "CZlib",
      providers: [
        .apt(["zlib1g-dev"])
      ]
    ),
    .target(
      name: "TangledLexicons",
      dependencies: [
        .product(name: "SwiftAtproto", package: "swift-atproto"),
        .product(name: "ATProtoMacro", package: "swift-atproto"),
      ],
      swiftSettings: [
        .enableUpcomingFeature("ApproachableConcurrency")
      ]
    ),
    .target(
      name: "SwiftTangled",
      dependencies: [
        "CZlib",
        "TangledLexicons",
        .product(name: "SwiftAtproto", package: "swift-atproto"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "OAuth4Swift", package: "oauth4swift"),
        .product(name: "GermConvenience", package: "GermConvenience"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
        .product(name: "WSClient", package: "swift-websocket"),
        .product(name: "Subprocess", package: "swift-subprocess"),
      ],
      swiftSettings: [
        .enableUpcomingFeature("ApproachableConcurrency")
      ]
    ),
    .executableTarget(
      name: "tng",
      dependencies: [
        "SwiftTangled",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Swiftdansi", package: "Swiftdansi"),
        .product(name: "Subprocess", package: "swift-subprocess"),
      ],
      swiftSettings: [
        .enableUpcomingFeature("ApproachableConcurrency")
      ]
    ),
    .executableTarget(
      name: "ManualSiteGenerator",
      path: "Tools/ManualSiteGenerator"
    ),
    .testTarget(
      name: "SwiftTangledTests",
      dependencies: [
        "CZlib",
        "SwiftTangled",
        "TangledLexicons",
        .product(name: "SwiftAtproto", package: "swift-atproto"),
        .product(name: "Crypto", package: "swift-crypto"),
      ],
      resources: [.copy("Fixtures")],
      swiftSettings: [
        .enableUpcomingFeature("ApproachableConcurrency")
      ]
    ),
    .testTarget(
      name: "TngTests",
      dependencies: [
        "SwiftTangled",
        "tng",
        .product(name: "SwiftAtproto", package: "swift-atproto"),
      ],
      swiftSettings: [
        .enableUpcomingFeature("ApproachableConcurrency")
      ]
    ),
    .testTarget(
      name: "ManualSiteGeneratorTests",
      dependencies: ["ManualSiteGenerator"]
    ),
  ]
)
