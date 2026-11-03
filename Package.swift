// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DropToMail",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DropToMail", targets: ["DropToMail"]),
        .library(name: "DropToMailCore", targets: ["DropToMailCore"])
    ],
    targets: [
        .systemLibrary(
            name: "CLibzip",
            pkgConfig: "libzip",
            providers: [.brew(["libzip"])]
        ),
        .target(
            name: "DropToMailCore",
            dependencies: ["CLibzip"]
        ),
        .executableTarget(
            name: "DropToMail",
            dependencies: ["DropToMailCore"]
        ),
        .testTarget(
            name: "DropToMailCoreTests",
            dependencies: ["DropToMailCore", "CLibzip"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
