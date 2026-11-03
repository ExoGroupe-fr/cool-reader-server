import Foundation

/// 7-Zip archives (CB7), dependency-free: headers (plain or LZMA-packed), folders and their files, with the Copy,
/// LZMA, LZMA2 and Deflate coders, which is what comic archives use. A folder is one compressed stream holding
/// its files one after the other (a "solid" archive keeps them all in one), so reading a file means decoding the
/// folder up to it: files decoded on the way wait in an `ArchiveCache` on disk, and the folder's decoder keeps its
/// place for the next page.
/// `ArchiveEntry.offset` is the file's index in `files`.
nonisolated final class SevenZipArchive: ArchiveReader, @unchecked Sendable {
    let entries: [ArchiveEntry]
    private let data: Data
    private let folders: [Folder]
    private let files: [FileItem]
    private let cache = ArchiveCache()
    private let lock = NSLock()
    /// The decoder of each folder being read, where it stopped.
    private var streams: [Int: FolderStream] = [:]

    static let signature: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]

    struct Coder {
        let id: [UInt8]
        let properties: [UInt8]
        let inStreams: Int
        let outStreams: Int
    }

    struct Folder {
        var coders: [Coder]
        /// Where the folder's packed data starts in the archive, and its size.
        var packOffset = 0
        var packSize = 0
        var unpackSize = 0
        /// The sizes and CRCs of the files it holds, in order.
        var fileSizes: [Int] = []
        var fileCRCs: [UInt32?] = []
    }

    struct FileItem {
        let folder: Int
        /// The file's position in its folder.
        let indexInFolder: Int
        let size: Int
        let crc: UInt32?
    }

    convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: [.alwaysMapped]))
    }

    init(data: Data) throws {
        self.data = data
        guard data.count >= 32, Array(data.prefix(6)) == Self.signature else { throw ArchiveError.notAnArchive }
        let nextOffset = Int(data.readLE(12, as: UInt64.self))
        let nextSize = Int(data.readLE(20, as: UInt64.self))
        guard nextOffset >= 0, nextSize > 0, data.hasBytes(at: 32 + nextOffset, count: nextSize) else {
            throw ArchiveError.corrupted
        }
        var header = data.subdata(in: (data.startIndex + 32 + nextOffset)..<(data.startIndex + 32 + nextOffset + nextSize))
        // A packed header: its streams info says how to decode the real one.
        var round = 0
        while header.first == Property.encodedHeader {
            round += 1
            guard round < 4 else { throw ArchiveError.corrupted }
            var reader = ByteReader(header)
            try reader.skip(1)
            let streams = try StreamsInfo(reader: &reader)
            guard let folder = streams.folders.first else { throw ArchiveError.corrupted }
            header = try Self.decodeWhole(folder: folder, data: data)
        }
        var reader = ByteReader(header)
        guard try reader.byte() == Property.header else { throw ArchiveError.corrupted }
        let parsed = try Self.readHeader(&reader)
        // Files get their folder and place in it.
        var files: [FileItem] = []
        var entries: [ArchiveEntry] = []
        var folderIndex = 0, indexInFolder = 0
        for (index, item) in parsed.items.enumerated() {
            if item.hasStream {
                while folderIndex < parsed.folders.count, indexInFolder >= parsed.folders[folderIndex].fileSizes.count {
                    folderIndex += 1
                    indexInFolder = 0
                }
                guard folderIndex < parsed.folders.count else { throw ArchiveError.corrupted }
                let folder = parsed.folders[folderIndex]
                files.append(FileItem(folder: folderIndex, indexInFolder: indexInFolder,
                                      size: folder.fileSizes[indexInFolder], crc: folder.fileCRCs[indexInFolder]))
                indexInFolder += 1
            } else {
                files.append(FileItem(folder: -1, indexInFolder: 0, size: 0, crc: nil))
            }
            let file = files[index]
            let folder = file.folder >= 0 ? parsed.folders[file.folder] : nil
            entries.append(ArchiveEntry(path: item.name.replacingOccurrences(of: "\\", with: "/"),
                                        uncompressedSize: UInt64(file.size), compressedSize: 0,
                                        method: folder.map(Self.methodNumber) ?? 0, offset: UInt64(index),
                                        isDirectory: item.isDirectory, isEncrypted: folder.map(Self.isEncrypted) ?? false))
        }
        self.folders = parsed.folders
        self.files = files
        self.entries = entries
    }

    func data(for entry: ArchiveEntry) throws -> Data {
        let index = Int(entry.offset)
        guard files.indices.contains(index) else { throw ArchiveError.entryNotFound(entry.path) }
        let file = files[index]
        guard file.folder >= 0 else { return Data() }
        if entry.isEncrypted { throw ArchiveError.encrypted }
        lock.lock()
        defer { lock.unlock() }
        let key = "\(file.folder)-\(file.indexInFolder)"
        if let cached = cache.data(for: key) { return cached }
        var stream = streams[file.folder]
        if stream == nil || stream!.nextIndex > file.indexInFolder {
            stream = try FolderStream(folder: folders[file.folder], data: data)
        }
        guard let stream else { throw ArchiveError.corrupted }
        streams[file.folder] = stream
        let folder = folders[file.folder]
        // Decode up to the file, keeping every file decoded on the way: pages come back (other sizes, the page after).
        while stream.nextIndex <= file.indexInFolder {
            let position = stream.nextIndex
            let output = try stream.next(size: folder.fileSizes[position])
            if let crc = folder.fileCRCs[position], CRC32.checksum(output) != crc { throw ArchiveError.corrupted }
            if folder.fileSizes.count > 1 { cache.store(output, for: "\(file.folder)-\(position)") }
            if position == file.indexInFolder {
                if stream.nextIndex >= folder.fileSizes.count { streams[file.folder] = nil }
                return output
            }
        }
        throw ArchiveError.corrupted
    }

    // MARK: - Coders

    static let aesCoder: [UInt8] = [0x06, 0xF1, 0x07, 0x01]

    private static func isEncrypted(_ folder: Folder) -> Bool {
        folder.coders.contains { $0.id == aesCoder }
    }

    private static func methodNumber(_ folder: Folder) -> UInt16 {
        guard let coder = folder.coders.first else { return 0 }
        switch coder.id {
        case [0x00]: return 0
        case [0x03, 0x01, 0x01]: return 14
        case [0x21]: return 21
        case [0x04, 0x01, 0x08]: return 8
        case [0x06, 0xF1, 0x07, 0x01]: return 0xAE5
        default: return 0xFFFF
        }
    }

    /// The decoder of one folder: a single coder (Copy, LZMA, LZMA2 or Deflate) reading its packed stream.
    final class FolderStream {
        private(set) var nextIndex = 0
        private var lzma: LZMADecoder?
        /// A copy of the packed stream the decoder reads, with room past its end for the range decoder.
        private let packed: UnsafeMutablePointer<UInt8>
        private let packedSize: Int
        private var packedPos = 0
        private var inflated: Data?
        private var inflatedPos = 0

        init(folder: Folder, data: Data) throws {
            if SevenZipArchive.isEncrypted(folder) { throw ArchiveError.encrypted }
            guard folder.coders.count == 1, let coder = folder.coders.first, coder.inStreams == 1, coder.outStreams == 1,
                  data.hasBytes(at: folder.packOffset, count: folder.packSize) else {
                throw ArchiveError.unsupportedCompression(SevenZipArchive.methodNumber(folder))
            }
            let size = folder.packSize
            packedSize = size
            packed = .allocate(capacity: size + 16)
            packed.initialize(repeating: 0, count: size + 16)
            data.copyBytes(to: packed, from: (data.startIndex + folder.packOffset)..<(data.startIndex + folder.packOffset + size))
            switch coder.id {
            case [0x00]:
                break
            case [0x03, 0x01, 0x01]:
                guard coder.properties.count >= 5, let properties = LZMAProperties(byte: coder.properties[0]) else {
                    throw ArchiveError.corrupted
                }
                let dictionary = Int(coder.properties[1]) | Int(coder.properties[2]) << 8 | Int(coder.properties[3]) << 16
                    | Int(coder.properties[4]) << 24
                lzma = try LZMADecoder(mode: .lzma(properties, dictionarySize: dictionary), input: packed, count: size,
                                       outputSize: folder.unpackSize)
            case [0x21]:
                guard let property = coder.properties.first, property <= 40 else { throw ArchiveError.corrupted }
                let dictionary = property == 40 ? Int(UInt32.max) : (2 | Int(property) & 1) << (Int(property) / 2 + 11)
                lzma = try LZMADecoder(mode: .lzma2(dictionarySize: dictionary), input: packed, count: size,
                                       outputSize: folder.unpackSize)
            case [0x04, 0x01, 0x08]:
                inflated = try ZipArchive.inflate(Data(bytesNoCopy: packed, count: size, deallocator: .none), range: 0..<size,
                                                  expectedSize: folder.unpackSize)
            default:
                throw ArchiveError.unsupportedCompression(SevenZipArchive.methodNumber(folder))
            }
        }

        deinit {
            lzma = nil
            packed.deallocate()
        }

        /// The next file of the folder.
        func next(size: Int) throws -> Data {
            defer { nextIndex += 1 }
            if size == 0 { return Data() }
            if let lzma {
                var output = Data(count: size)
                try output.withUnsafeMutableBytes { raw in
                    try lzma.read(into: raw.bindMemory(to: UInt8.self).baseAddress!, count: size)
                }
                return output
            }
            if let inflated {
                guard inflatedPos + size <= inflated.count else { throw ArchiveError.corrupted }
                defer { inflatedPos += size }
                return inflated.subdata(in: (inflated.startIndex + inflatedPos)..<(inflated.startIndex + inflatedPos + size))
            }
            guard packedPos + size <= packedSize else { throw ArchiveError.corrupted }
            defer { packedPos += size }
            return Data(bytes: packed + packedPos, count: size)
        }
    }

    /// A small folder decoded at once: the packed header.
    private static func decodeWhole(folder: Folder, data: Data) throws -> Data {
        let stream = try FolderStream(folder: folder, data: data)
        let output = try stream.next(size: folder.unpackSize)
        if let crc = folder.fileCRCs.first ?? nil, CRC32.checksum(output) != crc { throw ArchiveError.corrupted }
        return output
    }

    // MARK: - Header

    enum Property {
        static let end: UInt8 = 0x00
        static let header: UInt8 = 0x01
        static let archiveProperties: UInt8 = 0x02
        static let additionalStreamsInfo: UInt8 = 0x03
        static let mainStreamsInfo: UInt8 = 0x04
        static let filesInfo: UInt8 = 0x05
        static let packInfo: UInt8 = 0x06
        static let unpackInfo: UInt8 = 0x07
        static let substreamsInfo: UInt8 = 0x08
        static let size: UInt8 = 0x09
        static let crc: UInt8 = 0x0A
        static let folder: UInt8 = 0x0B
        static let codersUnpackSize: UInt8 = 0x0C
        static let numUnpackStream: UInt8 = 0x0D
        static let emptyStream: UInt8 = 0x0E
        static let emptyFile: UInt8 = 0x0F
        static let name: UInt8 = 0x11
        static let attributes: UInt8 = 0x15
        static let encodedHeader: UInt8 = 0x17
    }

    struct Item {
        var name = ""
        var hasStream = true
        var isDirectory = false
    }

    struct ParsedHeader {
        var folders: [Folder] = []
        var items: [Item] = []
    }

    private static func readHeader(_ reader: inout ByteReader) throws -> ParsedHeader {
        var parsed = ParsedHeader()
        var id = try reader.byte()
        if id == Property.archiveProperties {
            while try reader.byte() != Property.end { try reader.skip(Int(reader.number())) }
            id = try reader.byte()
        }
        if id == Property.additionalStreamsInfo {
            _ = try StreamsInfo(reader: &reader)
            id = try reader.byte()
        }
        if id == Property.mainStreamsInfo {
            parsed.folders = try StreamsInfo(reader: &reader).folders
            id = try reader.byte()
        }
        if id == Property.filesInfo {
            parsed.items = try readFiles(&reader)
            id = try reader.byte()
        }
        guard id == Property.end else { throw ArchiveError.corrupted }
        return parsed
    }

    /// PackInfo, UnpackInfo (folders and coders) and SubStreamsInfo (files in each folder).
    struct StreamsInfo {
        var folders: [Folder] = []

        init(reader: inout ByteReader) throws {
            var packPosition = 0
            var packSizes: [Int] = []
            var id = try reader.byte()
            if id == Property.packInfo {
                packPosition = Int(try reader.number())
                let count = Int(try reader.number())
                var property = try reader.byte()
                while property != Property.end {
                    if property == Property.size {
                        for _ in 0..<count { packSizes.append(Int(try reader.number())) }
                    } else if property == Property.crc {
                        _ = try reader.digests(count)
                    } else {
                        try reader.skip(Int(reader.number()))
                    }
                    property = try reader.byte()
                }
                id = try reader.byte()
            }
            if id == Property.unpackInfo {
                guard try reader.byte() == Property.folder else { throw ArchiveError.corrupted }
                let count = Int(try reader.number())
                guard count < 100_000, try reader.byte() == 0 else { throw ArchiveError.corrupted }
                var outStreams: [Int] = []
                for _ in 0..<count {
                    let (folder, outCount) = try Self.readFolder(&reader)
                    folders.append(folder)
                    outStreams.append(outCount)
                }
                guard try reader.byte() == Property.codersUnpackSize else { throw ArchiveError.corrupted }
                for index in folders.indices {
                    var sizes: [Int] = []
                    for _ in 0..<outStreams[index] { sizes.append(Int(try reader.number())) }
                    // With one coder the folder's output is its only out stream.
                    folders[index].unpackSize = sizes.last ?? 0
                }
                var property = try reader.byte()
                while property != Property.end {
                    if property == Property.crc {
                        let crcs = try reader.digests(folders.count)
                        for index in folders.indices { folders[index].fileCRCs = [crcs[index]] }
                    } else {
                        try reader.skip(Int(reader.number()))
                    }
                    property = try reader.byte()
                }
                id = try reader.byte()
            }
            // Packed streams follow each other from packPosition, one per folder for the coders handled here.
            var offset = 32 + packPosition
            for index in folders.indices {
                let size = index < packSizes.count ? packSizes[index] : 0
                folders[index].packOffset = offset
                folders[index].packSize = size
                offset += size
                folders[index].fileSizes = [folders[index].unpackSize]
                if folders[index].fileCRCs.isEmpty { folders[index].fileCRCs = [nil] }
            }
            if id == Property.substreamsInfo {
                var counts = [Int](repeating: 1, count: folders.count)
                var property = try reader.byte()
                if property == Property.numUnpackStream {
                    for index in folders.indices { counts[index] = Int(try reader.number()) }
                    property = try reader.byte()
                }
                var sizes: [[Int]] = folders.indices.map { _ in [] }
                for index in folders.indices where counts[index] > 0 {
                    var sum = 0
                    if property == Property.size {
                        for _ in 1..<counts[index] {
                            let size = Int(try reader.number())
                            sizes[index].append(size)
                            sum += size
                        }
                    }
                    guard folders[index].unpackSize >= sum else { throw ArchiveError.corrupted }
                    sizes[index].append(folders[index].unpackSize - sum)
                }
                if property == Property.size { property = try reader.byte() }
                var crcs: [[UInt32?]] = folders.indices.map { [UInt32?](repeating: nil, count: counts[$0]) }
                // Files of a one-file folder with a known CRC take the folder's.
                for index in folders.indices where counts[index] == 1 {
                    crcs[index][0] = folders[index].fileCRCs.first ?? nil
                }
                while property != Property.end {
                    if property == Property.crc {
                        let missing = folders.indices.reduce(0) { total, index in
                            total + (counts[index] == 1 && folders[index].fileCRCs.first! != nil ? 0 : counts[index])
                        }
                        let digests = try reader.digests(missing)
                        var next = 0
                        for index in folders.indices where !(counts[index] == 1 && folders[index].fileCRCs.first! != nil) {
                            for file in 0..<counts[index] {
                                crcs[index][file] = digests[next]
                                next += 1
                            }
                        }
                    } else {
                        try reader.skip(Int(reader.number()))
                    }
                    property = try reader.byte()
                }
                for index in folders.indices {
                    folders[index].fileSizes = sizes[index]
                    folders[index].fileCRCs = crcs[index]
                }
                id = try reader.byte()
            }
            guard id == Property.end else { throw ArchiveError.corrupted }
        }

        private static func readFolder(_ reader: inout ByteReader) throws -> (Folder, Int) {
            let count = Int(try reader.number())
            guard (1...32).contains(count) else { throw ArchiveError.corrupted }
            var coders: [Coder] = []
            var inTotal = 0, outTotal = 0
            for _ in 0..<count {
                let flags = try reader.byte()
                let id = try reader.bytes(Int(flags & 0x0F))
                var inStreams = 1, outStreams = 1
                if flags & 0x10 != 0 {
                    inStreams = Int(try reader.number())
                    outStreams = Int(try reader.number())
                }
                var properties: [UInt8] = []
                if flags & 0x20 != 0 { properties = try reader.bytes(Int(reader.number())) }
                coders.append(Coder(id: id, properties: properties, inStreams: inStreams, outStreams: outStreams))
                inTotal += inStreams
                outTotal += outStreams
            }
            // Bind pairs join the coders of a chain, then the packed streams if more than one.
            for _ in 0..<max(0, outTotal - 1) {
                _ = try reader.number()
                _ = try reader.number()
            }
            let packedStreams = inTotal - (outTotal - 1)
            if packedStreams > 1 {
                for _ in 0..<packedStreams { _ = try reader.number() }
            }
            return (Folder(coders: coders), outTotal)
        }
    }

    private static func readFiles(_ reader: inout ByteReader) throws -> [Item] {
        let count = Int(try reader.number())
        guard count < 1_000_000 else { throw ArchiveError.corrupted }
        var items = [Item](repeating: Item(), count: count)
        var emptyStreams: [Bool] = []
        var emptyFiles: [Bool] = []
        while true {
            let property = try reader.byte()
            if property == Property.end { break }
            let size = Int(try reader.number())
            var section = try reader.subreader(size)
            switch property {
            case Property.emptyStream:
                emptyStreams = try section.bits(count)
                for index in 0..<count where emptyStreams[index] { items[index].hasStream = false }
            case Property.emptyFile:
                emptyFiles = try section.bits(emptyStreams.filter { $0 }.count)
            case Property.name:
                guard try section.byte() == 0 else { throw ArchiveError.corrupted }
                for index in 0..<count { items[index].name = try section.utf16String() }
            case Property.attributes:
                let defined = try section.definedBits(count)
                _ = try section.byte()
                for index in 0..<count where defined[index] {
                    let attributes = try section.uint32()
                    if attributes & 0x10 != 0 { items[index].isDirectory = true }
                }
            default:
                break
            }
        }
        // Empty streams that aren't empty files are directories.
        var emptyIndex = 0
        for index in 0..<count where !items[index].hasStream {
            let isEmptyFile = emptyIndex < emptyFiles.count && emptyFiles[emptyIndex]
            if !isEmptyFile { items[index].isDirectory = true }
            emptyIndex += 1
        }
        return items
    }
}

/// Reads the numbers, bit fields and strings of 7-Zip headers.
nonisolated struct ByteReader {
    private let data: [UInt8]
    private var position = 0

    init(_ data: Data) { self.data = [UInt8](data) }
    private init(bytes: [UInt8]) { self.data = bytes }

    mutating func byte() throws -> UInt8 {
        guard position < data.count else { throw ArchiveError.corrupted }
        defer { position += 1 }
        return data[position]
    }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, position + count <= data.count else { throw ArchiveError.corrupted }
        defer { position += count }
        return Array(data[position..<(position + count)])
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, position + count <= data.count else { throw ArchiveError.corrupted }
        position += count
    }

    mutating func subreader(_ count: Int) throws -> ByteReader {
        ByteReader(bytes: try bytes(count))
    }

    /// 7-Zip's variable-length number: the first byte's high bits say how many bytes follow.
    mutating func number() throws -> UInt64 {
        let first = try byte()
        var mask: UInt8 = 0x80
        var value: UInt64 = 0
        for index in 0..<8 {
            if first & mask == 0 {
                return value | UInt64(first & (mask &- 1)) << (8 * index)
            }
            value |= UInt64(try byte()) << (8 * index)
            mask >>= 1
        }
        return value
    }

    mutating func uint32() throws -> UInt32 {
        let bytes = try bytes(4)
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    mutating func bits(_ count: Int) throws -> [Bool] {
        var result: [Bool] = []
        var current: UInt8 = 0
        for index in 0..<count {
            if index % 8 == 0 { current = try byte() }
            result.append(current & (0x80 >> (index % 8)) != 0)
        }
        return result
    }

    /// "All defined" then, if not, a bit per item.
    mutating func definedBits(_ count: Int) throws -> [Bool] {
        try byte() != 0 ? [Bool](repeating: true, count: count) : bits(count)
    }

    mutating func digests(_ count: Int) throws -> [UInt32?] {
        let defined = try definedBits(count)
        return try defined.map { try $0 ? uint32() : nil }
    }

    mutating func utf16String() throws -> String {
        var units: [UInt16] = []
        while true {
            let low = try byte(), high = try byte()
            let unit = UInt16(low) | UInt16(high) << 8
            if unit == 0 { break }
            units.append(unit)
        }
        return String(decoding: units, as: UTF16.self)
    }
}

/// CRC-32 (IEEE), as 7-Zip and RAR record for each file.
nonisolated enum CRC32 {
    static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data, initial: UInt32 = 0) -> UInt32 {
        var crc = ~initial
        data.withUnsafeBytes { raw in
            table.withUnsafeBufferPointer { table in
                for byte in raw.bindMemory(to: UInt8.self) {
                    crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        return ~crc
    }
}

/// Files already decoded from a solid stream, kept on disk while the archive is open.
nonisolated final class ArchiveCache: @unchecked Sendable {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ArchiveCache", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var created = false

    deinit { try? FileManager.default.removeItem(at: directory) }

    func store(_ data: Data, for key: String) {
        if !created {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            created = true
        }
        try? data.write(to: directory.appendingPathComponent(key))
    }

    func data(for key: String) -> Data? {
        guard created else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(key), options: [.alwaysMapped])
    }
}
