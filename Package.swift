// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cool-reader-server",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cool-reader-server", targets: ["CoolReaderServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        // The books, their formats, names and catalogues (Core/), and the server around them (Server/). Core/ only
        // uses Foundation and never Server/: it becomes the package the app shares once the app adopts it.
        .target(name: "CoolReaderKit", dependencies: [
            "CSQLite",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOFoundationCompat", package: "swift-nio"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "X509", package: "swift-certificates"),
        ]),
        .executableTarget(name: "CoolReaderServer", dependencies: ["CoolReaderKit"]),
        .testTarget(name: "CoolReaderKitTests", dependencies: ["CoolReaderKit"]),
    ]
)

#if os(macOS)
// The menu bar app, which runs the server in its own process (Scripts/build-mac-app.sh makes it an app). Linux and the
// Docker build never see it.
package.products.append(.executable(name: "CoolReaderServerMac", targets: ["CoolReaderServerMac"]))
package.targets.append(.executableTarget(name: "CoolReaderServerMac", dependencies: [
    "CoolReaderKit",
    .product(name: "NIOCore", package: "swift-nio"),
]))
#endif
