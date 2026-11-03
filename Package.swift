// swift-tools-version: 6.0
import PackageDescription

// libjpeg-turbo, libpng and libwebp shrink images where there is no ImageIO: on Linux, and on the Mac with
// COOLREADER_SYSTEM_IMAGE_LIBS=1 (Homebrew's jpeg-turbo, libpng and webp), to test that code.
let imageLibraryPlatforms: [Platform] =
    Context.environment["COOLREADER_SYSTEM_IMAGE_LIBS"] == "1" ? [.linux, .macOS] : [.linux]

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
            .target(name: "CTurboJPEG", condition: .when(platforms: imageLibraryPlatforms)),
            .target(name: "CPNG", condition: .when(platforms: imageLibraryPlatforms)),
            .target(name: "CWebP", condition: .when(platforms: imageLibraryPlatforms)),
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
        .systemLibrary(name: "CTurboJPEG", pkgConfig: "libturbojpeg",
                       providers: [.apt(["libturbojpeg0-dev"]), .brew(["jpeg-turbo"])]),
        .systemLibrary(name: "CPNG", pkgConfig: "libpng", providers: [.apt(["libpng-dev"]), .brew(["libpng"])]),
        .systemLibrary(name: "CWebP", pkgConfig: "libwebp", providers: [.apt(["libwebp-dev"]), .brew(["webp"])]),
    ]
)
