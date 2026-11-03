import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

nonisolated struct ImageData: Sendable {
    var data: Data
    var contentType: String
}

/// Covers and pages. Covers are shrunk once and kept in the cache folder; remote covers (AniList, MangaDex, Apple
/// Books, Open Library) are downloaded once. Pages come straight from the archive, which stays open a while.
nonisolated final class Images: Sendable {
    private let cache: URL
    private let archives = ArchivePool(capacity: 8)
    static let coverSize = 600.0
    /// The longest side of a PDF page drawn when the reader asks for no width.
    static let pdfPageSize = 1600.0

    init(cacheDirectory: URL) {
        cache = cacheDirectory
        try? FileManager.default.createDirectory(at: cache.appendingPathComponent("covers"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cache.appendingPathComponent("remote"), withIntermediateDirectories: true)
    }

    /// A book's cover: the catalogue's cover of that volume, else its first page (or the PDF's).
    func bookCover(_ book: BookRecord, series: SeriesRecord, root: URL) async -> ImageData? {
        if let remote = series.match?.bookCovers[String(book.id)], let image = await remoteImage(remote) { return image }
        return localCover(book, root: root)
    }

    /// A series' cover: the poster in its folder, the catalogue's cover, else its first book's.
    func seriesCover(_ series: SeriesRecord, books: [BookRecord], root: URL) async -> ImageData? {
        if let poster = series.posterPath {
            let url = root.appendingPathComponent(poster)
            if let data = try? Data(contentsOf: url) { return cached("poster-\(series.id)-\(stamp(url))") { data } }
        }
        if let remote = series.match?.coverURL, let image = await remoteImage(remote) { return image }
        guard let first = books.first else { return nil }
        return localCover(first, root: root)
    }

    func banner(_ series: SeriesRecord, root: URL) async -> ImageData? {
        if let banner = series.bannerPath, let data = try? Data(contentsOf: root.appendingPathComponent(banner)) {
            return ImageData(data: data, contentType: BookFormat.imageMediaType(banner))
        }
        if let remote = series.match?.bannerURL { return await remoteImage(remote, shrink: false) }
        return nil
    }

    /// One page of an image book, at most `maxWidth` pixels wide where the platform can resize. PDF pages are drawn,
    /// 1600 pixels on their longest side when no width is asked for.
    func page(_ book: BookRecord, index: Int, maxWidth: Double?, root: URL) throws -> ImageData {
        let url = root.appendingPathComponent(book.path)
        if book.format == .pdf {
            guard (0..<(book.pageCount ?? 0)).contains(index),
                  let data = PDFPages.render(url: url, page: index, maxPixelSize: maxWidth ?? Self.pdfPageSize) else {
                throw HTTPError.notFound
            }
            return ImageData(data: data, contentType: "image/jpeg")
        }
        guard book.pagePaths.indices.contains(index) else { throw HTTPError.notFound }
        let archive = try archives.archive(for: url, format: book.format)
        let path = book.pagePaths[index]
        let data = try archive.data(atPath: path)
        if let maxWidth, let small = Thumbnailer.jpeg(data, maxPixelSize: maxWidth) {
            return ImageData(data: small, contentType: "image/jpeg")
        }
        return ImageData(data: data, contentType: BookFormat.imageMediaType(path))
    }

    private func localCover(_ book: BookRecord, root: URL) -> ImageData? {
        let url = root.appendingPathComponent(book.path)
        return cached("book-\(book.id)-\(stamp(url))") {
            if book.format == .pdf { return PDFPages.cover(url: url, maxPixelSize: Self.coverSize) }
            guard let entry = book.coverPath, let archive = try? archives.archive(for: url, format: book.format) else { return nil }
            return try? archive.data(atPath: entry)
        }
    }

    private func remoteImage(_ url: URL, shrink: Bool = true) async -> ImageData? {
        let key = "remote-" + SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        if let image = cached(key, produce: { nil }) { return image }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("CoolReaderServer/0.1 (+https://github.com/pookee/cool-reader-server)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400, !data.isEmpty else { return nil }
        return shrink ? cached(key) { data } : ImageData(data: data, contentType: "image/jpeg")
    }

    /// The cached cover named `key`, or the one made from `produce`: shrunk to a JPEG where the platform can.
    private func cached(_ key: String, produce: () -> Data?) -> ImageData? {
        let file = cache.appendingPathComponent("covers").appendingPathComponent(key)
        if let data = try? Data(contentsOf: file) { return ImageData(data: data, contentType: Self.contentType(of: data)) }
        guard let original = produce() else { return nil }
        let data = Thumbnailer.jpeg(original, maxPixelSize: Self.coverSize) ?? original
        try? data.write(to: file, options: .atomic)
        return ImageData(data: data, contentType: Self.contentType(of: data))
    }

    private func stamp(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return String(Int(modified))
    }

    /// What an image is by its first bytes.
    static func contentType(of data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if bytes.count >= 12, bytes.starts(with: [0x52, 0x49, 0x46, 0x46]), bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        if bytes.count >= 12, bytes[4...7] == [0x66, 0x74, 0x79, 0x70] { return bytes[8...11] == [0x61, 0x76, 0x69, 0x66] ? "image/avif" : "image/heic" }
        return "application/octet-stream"
    }
}

/// Archives kept open for a few minutes: a reader turning pages of a solid RAR doesn't decode it from the start
/// for each page.
nonisolated final class ArchivePool: @unchecked Sendable {
    private let capacity: Int
    private var entries: [(key: String, archive: any ArchiveReader, used: Date)] = []
    private let lock = NSLock()

    init(capacity: Int) { self.capacity = capacity }

    func archive(for url: URL, format: BookFormat) throws -> any ArchiveReader {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)"
        lock.lock()
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].used = Date()
            let archive = entries[index].archive
            lock.unlock()
            return archive
        }
        lock.unlock()
        let archive: any ArchiveReader = format == .epub ? try ZipArchive(url: url) : try BookOpener.archive(url: url, format: format)
        lock.lock()
        entries.removeAll { $0.key.hasPrefix(url.path + "|") }
        entries.append((key, archive, Date()))
        let stale = Date().addingTimeInterval(-300)
        entries.removeAll { $0.used < stale && $0.key != key }
        if entries.count > capacity {
            entries.sort { $0.used > $1.used }
            entries.removeLast(entries.count - capacity)
        }
        lock.unlock()
        return archive
    }
}

/// Shrinks images to JPEG: with ImageIO on the Mac, with libjpeg-turbo, libpng and libwebp on Linux. Formats those
/// libraries don't read (GIF, AVIF, HEIC…) go out as they are.
nonisolated enum Thumbnailer {
    static func jpeg(_ data: Data, maxPixelSize: Double) -> Data? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo),
           let canvas = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            // JPEG has no transparency: lay it on white, as Linux does, rather than ImageIO's black.
            let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            canvas.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            canvas.fill(frame)
            canvas.draw(image, in: frame)
            if let flattened = canvas.makeImage() { image = flattened }
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
        #elseif canImport(CTurboJPEG) && canImport(CPNG) && canImport(CWebP)
        ImageCodecs.thumbnail(data, maxPixelSize: maxPixelSize)
        #else
        nil
        #endif
    }
}
