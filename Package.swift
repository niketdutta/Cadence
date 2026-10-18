// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Cadence",
    platforms: [.macOS("26.0")],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")],
    targets: [.executableTarget(name: "Cadence", dependencies: [.product(name: "Sparkle", package: "Sparkle")],
                                linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])])]
)
