import Foundation

/// Minimal, dependency-free ZIP reader (CBZ, EPUB, ZIP): reads the central directory, supports ZIP64,
/// stored and deflated entries. The file is memory-mapped, so opening a 500 MB archive is instant and
/// pages are read on demand.
nonisolated final class ZipArchive: ArchiveReader, @unchecked Sendable {
    let entries: [ArchiveEntry]
    private let data: Data

    convenience init(url: URL) throws {
        let data = try Data(contentsOf: url, options: [.alwaysMapped])
        try self.init(data: data)
    }

    init(data: Data) throws {
        self.data = data
        self.entries = try Self.readCentralDirectory(data)
    }

    func data(for entry: ArchiveEntry) throws -> Data {
        if entry.isEncrypted { throw ArchiveError.encrypted }
        let headerOffset = Int(entry.offset)
        guard data.hasBytes(at: headerOffset, count: 30),
              data.readLE(headerOffset, as: UInt32.self) == 0x0403_4B50 else { throw ArchiveError.corrupted }
        let nameLength = Int(data.readLE(headerOffset + 26, as: UInt16.self))
        let extraLength = Int(data.readLE(headerOffset + 28, as: UInt16.self))
        let start = headerOffset + 30 + nameLength + extraLength
        let compressedSize = Int(entry.compressedSize)
        guard data.hasBytes(at: start, count: compressedSize) else { throw ArchiveError.corrupted }
        let range = (data.startIndex + start)..<(data.startIndex + start + compressedSize)

        switch entry.method {
        case 0:
            return data.subdata(in: range)
        case 8:
            return try Self.inflate(data, range: range, expectedSize: Int(entry.uncompressedSize))
        default:
            throw ArchiveError.unsupportedCompression(entry.method)
        }
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ data: Data) throws -> [ArchiveEntry] {
        guard data.count >= 22 else { throw ArchiveError.notAnArchive }
        let eocd = try findEndOfCentralDirectory(data)
        var entryCount = UInt64(data.readLE(eocd + 10, as: UInt16.self))
        var directorySize = UInt64(data.readLE(eocd + 12, as: UInt32.self))
        var directoryOffset = UInt64(data.readLE(eocd + 16, as: UInt32.self))

        // ZIP64: the locator sits right before the classic end record.
        let locator = eocd - 20
        if locator >= 0, data.readLE(locator, as: UInt32.self) == 0x0706_4B50 {
            let zip64Offset = Int(data.readLE(locator + 8, as: UInt64.self))
            if data.hasBytes(at: zip64Offset, count: 56), data.readLE(zip64Offset, as: UInt32.self) == 0x0606_4B50 {
                entryCount = data.readLE(zip64Offset + 32, as: UInt64.self)
                directorySize = data.readLE(zip64Offset + 40, as: UInt64.self)
                directoryOffset = data.readLE(zip64Offset + 48, as: UInt64.self)
            }
        }
        guard data.hasBytes(at: Int(directoryOffset), count: Int(directorySize)) else { throw ArchiveError.corrupted }

        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(Int(min(entryCount, 100_000)))
        var cursor = Int(directoryOffset)
        let end = Int(directoryOffset + directorySize)
        while cursor + 46 <= end, data.readLE(cursor, as: UInt32.self) == 0x0201_4B50 {
            let flags = data.readLE(cursor + 8, as: UInt16.self)
            let method = data.readLE(cursor + 10, as: UInt16.self)
            var compressedSize = UInt64(data.readLE(cursor + 20, as: UInt32.self))
            var uncompressedSize = UInt64(data.readLE(cursor + 24, as: UInt32.self))
            let nameLength = Int(data.readLE(cursor + 28, as: UInt16.self))
            let extraLength = Int(data.readLE(cursor + 30, as: UInt16.self))
            let commentLength = Int(data.readLE(cursor + 32, as: UInt16.self))
            let externalAttributes = data.readLE(cursor + 38, as: UInt32.self)
            var localOffset = UInt64(data.readLE(cursor + 42, as: UInt32.self))
            guard data.hasBytes(at: cursor + 46, count: nameLength + extraLength) else { throw ArchiveError.corrupted }

            let nameData = data.subdata(in: (data.startIndex + cursor + 46)..<(data.startIndex + cursor + 46 + nameLength))
            var name = decodeName(nameData, utf8: flags & 0x0800 != 0)

            // Extra fields: ZIP64 sizes/offset and Info-ZIP Unicode path.
            var extra = cursor + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = data.readLE(extra, as: UInt16.self)
                let size = Int(data.readLE(extra + 2, as: UInt16.self))
                let body = extra + 4
                guard body + size <= extraEnd else { break }
                if id == 0x0001 {
                    var field = body
                    if uncompressedSize == 0xFFFF_FFFF, field + 8 <= body + size {
                        uncompressedSize = data.readLE(field, as: UInt64.self); field += 8
                    }
                    if compressedSize == 0xFFFF_FFFF, field + 8 <= body + size {
                        compressedSize = data.readLE(field, as: UInt64.self); field += 8
                    }
                    if localOffset == 0xFFFF_FFFF, field + 8 <= body + size {
                        localOffset = data.readLE(field, as: UInt64.self)
                    }
                } else if id == 0x7075, size > 5 {
                    let utf8 = data.subdata(in: (data.startIndex + body + 5)..<(data.startIndex + body + size))
                    if let unicodeName = String(data: utf8, encoding: .utf8) { name = unicodeName }
                }
                extra = body + size
            }

            let isDirectory = name.hasSuffix("/") || (externalAttributes >> 16) & 0o170000 == 0o040000
            entries.append(ArchiveEntry(
                path: name,
                uncompressedSize: uncompressedSize,
                compressedSize: compressedSize,
                method: method,
                offset: localOffset,
                isDirectory: isDirectory,
                isEncrypted: flags & 0x0001 != 0
            ))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        if entries.isEmpty && entryCount > 0 { throw ArchiveError.corrupted }
        return entries
    }

    private static func findEndOfCentralDirectory(_ data: Data) throws -> Int {
        let lowest = max(0, data.count - 22 - 0xFFFF)
        var offset = data.count - 22
        while offset >= lowest {
            if data.readLE(offset, as: UInt32.self) == 0x0605_4B50 { return offset }
            offset -= 1
        }
        throw ArchiveError.notAnArchive
    }

    private static func decodeName(_ data: Data, utf8: Bool) -> String {
        if utf8, let name = String(data: data, encoding: .utf8) { return name }
        // Most archives without the UTF-8 flag are still UTF-8 in practice; fall back to CP437 otherwise.
        if let name = String(data: data, encoding: .utf8) { return name }
        return CP437.decode(data)
    }

    // MARK: - Deflate

    /// Raw DEFLATE (RFC 1951), decoded by `Inflate`.
    static func inflate(_ data: Data, range: Range<Int>, expectedSize: Int) throws -> Data {
        try data.withUnsafeBytes { raw in
            let start = range.lowerBound - data.startIndex
            return try Inflate.decode(UnsafeRawBufferPointer(rebasing: raw[start..<(start + range.count)]), expectedSize: expectedSize)
        }
    }
}
