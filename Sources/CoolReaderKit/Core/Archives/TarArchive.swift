import Foundation

/// TAR reader (CBT): ustar and GNU long names, memory-mapped.
nonisolated final class TarArchive: ArchiveReader, @unchecked Sendable {
    let entries: [ArchiveEntry]
    private let data: Data

    convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: [.alwaysMapped]))
    }

    init(data: Data) throws {
        self.data = data
        self.entries = try Self.readEntries(data)
    }

    func data(for entry: ArchiveEntry) throws -> Data {
        let start = Int(entry.offset)
        let count = Int(entry.uncompressedSize)
        guard data.hasBytes(at: start, count: count) else { throw ArchiveError.corrupted }
        return data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + count))
    }

    private static func readEntries(_ data: Data) throws -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var cursor = 0
        var pendingLongName: String?
        while data.hasBytes(at: cursor, count: 512) {
            let header = data.subdata(in: (data.startIndex + cursor)..<(data.startIndex + cursor + 512))
            if header.allSatisfy({ $0 == 0 }) { break }
            guard let size = octal(header, 124, 12) else {
                if entries.isEmpty { throw ArchiveError.notAnArchive }
                break
            }
            let type = header[header.startIndex + 156]
            var name = string(header, 0, 100)
            let magic = string(header, 257, 6)
            if magic.hasPrefix("ustar") {
                let prefix = string(header, 345, 155)
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            let dataStart = cursor + 512
            if type == UInt8(ascii: "L") {
                // GNU long name: the data block holds the name of the next entry.
                if data.hasBytes(at: dataStart, count: Int(size)) {
                    let raw = data.subdata(in: (data.startIndex + dataStart)..<(data.startIndex + dataStart + Int(size)))
                    pendingLongName = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
            } else {
                if let longName = pendingLongName { name = longName; pendingLongName = nil }
                let isFile = type == 0 || type == UInt8(ascii: "0") || type == UInt8(ascii: "7")
                let isDirectory = type == UInt8(ascii: "5")
                if isFile || isDirectory {
                    entries.append(ArchiveEntry(path: name, uncompressedSize: size, compressedSize: size, method: 0,
                                                offset: UInt64(dataStart), isDirectory: isDirectory, isEncrypted: false))
                }
            }
            cursor = dataStart + Int((size + 511) / 512 * 512)
        }
        if entries.isEmpty { throw ArchiveError.notAnArchive }
        return entries
    }

    private static func string(_ header: Data, _ offset: Int, _ length: Int) -> String {
        let slice = header[(header.startIndex + offset)..<(header.startIndex + offset + length)]
        return String(decoding: slice.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func octal(_ header: Data, _ offset: Int, _ length: Int) -> UInt64? {
        let text = string(header, offset, length).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\0")))
        if text.isEmpty { return 0 }
        return UInt64(text, radix: 8)
    }
}
