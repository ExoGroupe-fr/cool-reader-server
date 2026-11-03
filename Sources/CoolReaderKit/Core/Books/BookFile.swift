import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif
#if canImport(Glibc)
import Glibc
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

/// PDF pages are counted and drawn with Core Graphics where there is one (the Mac app), and with Poppler's pdfinfo
/// and pdftoppm on Linux (poppler-utils). Without them a PDF has no page count, cover nor page images.
nonisolated enum PDFPages {
    static func count(url: URL) -> Int? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        CGPDFDocument(url as CFURL).map(\.numberOfPages)
        #elseif os(Linux)
        Poppler.pageCount(url: url)
        #else
        nil
        #endif
    }

    /// The first page as a JPEG whose longest side is `maxPixelSize`.
    static func cover(url: URL, maxPixelSize: Double) -> Data? {
        render(url: url, page: 0, maxPixelSize: maxPixelSize)
    }

    /// Page `page` (from 0) as a JPEG whose longest side is `maxPixelSize`: on white, cut to the crop box and
    /// turned by the page's /Rotate.
    static func render(url: URL, page: Int, maxPixelSize: Double) -> Data? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard page >= 0, maxPixelSize >= 1, let document = CGPDFDocument(url as CFURL), page < document.numberOfPages,
              let pdfPage = document.page(at: page + 1) else { return nil }
        let box = pdfPage.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let rotation = (Int(pdfPage.rotationAngle) % 360 + 360) % 360
        let size = rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
        let scale = maxPixelSize / max(size.width, size.height)
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        // /Rotate turns the page clockwise; Core Graphics' y axis goes up.
        switch rotation {
        case 90:
            context.translateBy(x: 0, y: size.height)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: size.width, y: size.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: size.width, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(pdfPage)
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
        #elseif os(Linux)
        Poppler.render(url: url, page: page, maxPixelSize: maxPixelSize)
        #else
        nil
        #endif
    }
}

#if os(macOS) || os(Linux)
/// Poppler's command-line tools, which read PDFs on Linux. They are looked for in /usr/bin and /usr/local/bin only,
/// run without a shell, and killed after 20 seconds.
nonisolated enum Poppler {
    static let directories = ["/usr/bin", "/usr/local/bin"]
    static let timeout: TimeInterval = 20

    /// The page count pdfinfo reads; nil without pdfinfo, or for a damaged or locked PDF.
    static func pageCount(url: URL, in directories: [String] = Poppler.directories) -> Int? {
        inTemporaryFolder { folder in
            let output = folder.appendingPathComponent("info.txt")
            guard run("pdfinfo", [path(of: url)], in: directories, output: output),
                  let info = try? Data(contentsOf: output) else { return nil }
            // The last "Pages:" line is pdfinfo's own, after the title and the other metadata.
            let line = String(decoding: info, as: UTF8.self).split(whereSeparator: \.isNewline)
                .last { $0.hasPrefix("Pages:") }
            return line.flatMap { Int($0.dropFirst(6).trimmingCharacters(in: .whitespaces)) }
        }
    }

    /// Page `page` (from 0) drawn by pdftoppm as a JPEG whose longest side is `maxPixelSize`, cut to the crop box.
    static func render(url: URL, page: Int, maxPixelSize: Double,
                       in directories: [String] = Poppler.directories) -> Data? {
        guard page >= 0, maxPixelSize >= 1 else { return nil }
        return inTemporaryFolder { folder in
            let image = folder.appendingPathComponent("page")
            let number = String(page + 1)
            let arguments = ["-f", number, "-l", number, "-scale-to", String(Int(maxPixelSize.rounded())), "-cropbox",
                             "-jpeg", "-jpegopt", "quality=85", "-singlefile", path(of: url), image.path]
            guard run("pdftoppm", arguments, in: directories, output: folder.appendingPathComponent("log.txt")) else {
                return nil
            }
            return try? Data(contentsOf: image.appendingPathExtension("jpg"))
        }
    }

    /// The file's path, never mistaken for an option.
    private static func path(of url: URL) -> String {
        url.path.hasPrefix("-") ? "./" + url.path : url.path
    }

    private static func inTemporaryFolder<Result>(_ body: (URL) -> Result?) -> Result? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coolreader-" + UUID().uuidString)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        return body(folder)
    }

    /// Runs `tool` with its standard output in the file `output`; false when it isn't installed, fails, or runs
    /// past the timeout. A file rather than a pipe: a tool that prints a lot would wait for a pipe to be read.
    private static func run(_ tool: String, _ arguments: [String], in directories: [String], output: URL) -> Bool {
        guard let executable = directories.map({ URL(fileURLWithPath: $0).appendingPathComponent(tool) })
                  .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }),
              FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else { return false }
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return false }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 5)
            return false
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
    }
}
#endif
