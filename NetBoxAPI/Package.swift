// swift-tools-version: 6.0
//
// Isolated module for the generated NetBox client.
// Pulse already owns a type named `Configuration`; the generated
// `Client` takes `OpenAPIRuntime.Configuration`. They cannot share
// a module. This package is also the build-cost firewall: 54k lines
// of generated Swift compile once here.

import PackageDescription

let package = Package(
    name: "NetBoxAPI",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "NetBoxAPI", targets: ["NetBoxAPI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.12.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", exact: "1.3.1"),
        .package(url: "https://github.com/apple/swift-http-types", exact: "1.6.0"),
    ],
    targets: [
        .target(
            name: "NetBoxAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            path: "Sources/NetBoxAPI"
        ),
    ]
)
