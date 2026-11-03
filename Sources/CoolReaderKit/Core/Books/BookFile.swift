import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// The kinds of books the server reads, by file extension.
nonisolated enum BookFormat: String, Codable, Sendable, CaseIterable {
    case pdf
    case cbz
    case cbr
    case cb7
    case cbt
    case epub

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "pdf": self = .pdf
        case "cbz", "zip": self = .cbz
        case "cbr", "rar": self = .cbr
        case "cb7", "7z": self = .cb7
        case "cbt", "tar": self = .cbt
        case "epub": self = .epub
        default: return nil
        }
    }

    /// The media type of the file itself, for downloads and OPDS acquisition links.
    var mediaType: String {
        switch self {
        case .pdf: "application/pdf"
        case .cbz: "application/vnd.comicbook+zip"
        case .cbr: "application/vnd.comicbook-rar"
        case .cb7: "application/x-cb7"
        case .cbt: "application/x-cbt"
        case .epub: "application/epub+zip"
        }
    }

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff", "jxl",
    ]

    static func isImage(_ fileName: String) -> Bool {
        imageExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    static func imageMediaType(_ fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic", "heif": "image/heic"
        case "avif": "image/avif"
        case "bmp": "image/bmp"
        case "tif", "tiff": "image/tiff"
        case "jxl": "image/jxl"
        default: "application/octet-stream"
        }
    }
}

/// "page 2" before "page 10", without regard to case or accents: the order the app gets from
/// `localizedStandardCompare`, written out so that it is the same on every platform.
nonisolated enum NaturalOrder {
    static func less(_ a: String, _ b: String) -> Bool {
        let left = runs(a), right = runs(b)
        for (l, r) in zip(left, right) where l != r {
            if let first = l.first, let other = r.first, isDigit(first), isDigit(other) {
                let lv = l.drop { $0 == "0" }, rv = r.drop { $0 == "0" }
                if lv.count != rv.count { return lv.count < rv.count }
                if lv != rv { return lv < rv }
                return l.count < r.count
            }
            return l < r
        }
        return left.count != right.count ? left.count < right.count : a < b
    }

    private static func isDigit(_ character: Character) -> Bool { ("0"..."9").contains(character) }

    private static func runs(_ text: String) -> [Substring] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var runs: [Substring] = []
        var start = folded.startIndex
        var index = folded.startIndex
        while index < folded.endIndex {
            let next = folded.index(after: index)
            if next == folded.endIndex || isDigit(folded[index]) != isDigit(folded[next]) {
                runs.append(folded[start..<next])
                start = next
            }
            index = next
        }
        return runs
    }
}

nonisolated enum BookOpener {
    /// The reader of a comic archive, chosen by its first bytes rather than its extension: many ".cbr" files are
    /// ZIP archives, and the other way round.
    static func archive(url: URL, format: BookFormat) throws -> any ArchiveReader {
        let handle = try FileHandle(forReadingFrom: url)
        let head = try handle.read(upToCount: 8) ?? Data()
        try? handle.close()
        if head.starts(with: [0x50, 0x4B]) { return try ZipArchive(url: url) }
        if head.starts(with: RarArchive.signature4) || head.starts(with: RarArchive.signature5) { return try RarArchive(url: url) }
        if head.starts(with: SevenZipArchive.signature) { return try SevenZipArchive(url: url) }
        switch format {
        case .cbr: return try RarArchive(url: url)
        case .cb7: return try SevenZipArchive(url: url)
        case .cbt: return try TarArchive(url: url)
        default: return try ZipArchive(url: url)
        }
    }

    /// The pages of an image archive: every image in natural order, without macOS's metadata files.
    static func imagePages(of archive: any ArchiveReader) -> [String] {
        archive.entries
            .filter { entry in
                !entry.isDirectory && BookFormat.isImage(entry.path) && !entry.path.hasPrefix("__MACOSX/")
                    && !entry.fileName.hasPrefix(".")
            }
            .map(\.path)
            .sorted(by: NaturalOrder.less)
    }
}

/// What the server learns from a book file when it scans it: its pages, its cover and the metadata it carries.
nonisolated struct BookAnalysis: Sendable, Equatable {
    /// Paths of the page images inside the archive, in reading order; empty for PDFs and text EPUBs.
    var pagePaths: [String] = []
    var pageCount: Int?
    /// The archive entry of the cover image.
    var coverPath: String?
    var metadata: EmbeddedMetadata?
    /// A text EPUB, read as reflowable text rather than pages.
    var isText = false

    static func analyze(url: URL, format: BookFormat) throws -> BookAnalysis {
        var analysis = BookAnalysis()
        switch format {
        case .cbz, .cbr, .cb7, .cbt:
            let archive = try BookOpener.archive(url: url, format: format)
            analysis.pagePaths = BookOpener.imagePages(of: archive)
            guard !analysis.pagePaths.isEmpty else { throw BookOpenError.empty }
            analysis.pageCount = analysis.pagePaths.count
            analysis.coverPath = analysis.pagePaths.first
            let comicInfo = archive.entries.first { $0.fileName.caseInsensitiveCompare("ComicInfo.xml") == .orderedSame }
            analysis.metadata = comicInfo.flatMap { try? archive.data(for: $0) }.flatMap(ComicInfo.parse)
        case .epub:
            let archive = try ZipArchive(url: url)
            let package = try EPUBPackage(archive: archive)
            analysis.metadata = package.metadata
            if let images = package.imagePagePaths(), !images.isEmpty {
                analysis.pagePaths = images
                analysis.pageCount = images.count
                analysis.coverPath = package.coverImagePath ?? images.first
            } else {
                analysis.isText = true
                analysis.coverPath = package.coverImagePath
            }
        case .pdf:
            analysis.pageCount = PDFPages.count(url: url)
        }
        return analysis
    }
}

/// PDF pages are counted and drawn with Core Graphics where there is one (the Mac app); on Linux a PDF has
/// no page count nor cover until a renderer is added.
nonisolated enum PDFPages {
    static func count(url: URL) -> Int? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        CGPDFDocument(url as CFURL).map(\.numberOfPages)
        #else
        nil
        #endif
    }

    /// The first page as a JPEG whose longest side is `maxPixelSize`.
    static func cover(url: URL, maxPixelSize: Double) -> Data? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = maxPixelSize / max(box.width, box.height)
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
        #else
        nil
        #endif
    }
}
