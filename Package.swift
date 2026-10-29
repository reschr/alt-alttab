// swift-tools-version: 6.0
import PackageDescription

// AppKit is provided by macOS, so the app needs no third-party packages.
let package = Package(
    name: "AltAltTab",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AltAltTab", targets: ["AltAltTab"])],
    targets: [.executableTarget(name: "AltAltTab")]
)
