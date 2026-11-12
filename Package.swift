// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "StockbeeMac",
    platforms: [.macOS(.v13)],
    products: [.library(name: "StockbeeCore", targets: ["StockbeeCore"])],
    targets: [
        .target(name: "StockbeeCore", path: "Sources/StockbeeCore"),
        .testTarget(name: "StockbeeCoreTests", dependencies: ["StockbeeCore"], path: "Tests/StockbeeCoreTests", resources: [.process("Resources")])
    ]
)
