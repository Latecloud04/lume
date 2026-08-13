// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Lume",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LumeCore", targets: ["LumeCore"]),
        .executable(name: "Lume", targets: ["Lume"]),
        .executable(name: "LumeTests", targets: ["LumeTests"]),
    ],
    targets: [
        .target(name: "LumeCore"),
        .executableTarget(name: "Lume", dependencies: ["LumeCore"]),
        .executableTarget(name: "LumeTests", dependencies: ["LumeCore"]),
    ]
)
