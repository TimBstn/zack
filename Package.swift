// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Zack",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Zack", targets: ["Zack"])],
    targets: [.executableTarget(name: "Zack", path: "Sources")]
)
