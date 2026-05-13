// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hyprtile",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(
            name: "Hyprtile",
            targets: ["Hyprtile"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "Hyprtile",
            path: "Sources/Hyprtile"
        ),
    ]
)
