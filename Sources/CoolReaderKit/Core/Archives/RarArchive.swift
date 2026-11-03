import Foundation

/// RAR archives (CBR), versions 1.5 to 4 and 5, dependency-free: the headers, then each file stored or compressed
/// (`RarUnpacker`). In a solid archive a file continues the compression of the previous ones, so reading it means
/// decoding the run from its first file: files decoded on the way wait in an `ArchiveCache`, and the unpacker keeps
/// its place for the next page. Password-protected and multi-volume archives aren't read.
/// `ArchiveEntry.offset` is the file's index in `files`.
nonisolated final class RarArchive: ArchiveReader, @unchecked Sendable {
    let entries: [ArchiveEntry]
    private let data: Data
    private let files: [FileItem]
    private let cache = ArchiveCache()
    private let lock = NSLock()
    /// The unpacker of the solid run being read, and the next file it would decode.
    private var solidUnpacker: RarUnpacker?
    private var solidRun = -1
    private var solidNext = 0

    static let signature4: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
    static let signature5: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]

    struct FileItem {
        var path: String
        var dataOffset: Int
        var packedSize: Int
        var unpackedSize: Int
        var crc: UInt32?
        var isStored: Bool
        var algorithm: RarUnpacker.Algorithm?
        var dictionarySize: Int
        var isSolid: Bool
        var isDirectory: Bool
        var isEncrypted: Bool
        var isSplit: Bool
        /// The path of the file this one is identical to, for files saved as references (WinRAR's `-oi`) and hard links.
        var original: String?

        /// Whether the unpacker reads this file: in a solid run, only these continue the stream. An empty file can
        /// come without packed data, even marked solid.
        var isPacked: Bool { !isStored && !isDirectory && original == nil && packedSize > 0 }
    }

    convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: [.alwaysMapped]))
    }

    init(data: Data) throws {
        self.data = data
        let files: [FileItem]
        if data.starts(with: Self.signature5) {
            files = try Self.readRar5(data)
        } else if data.starts(with: Self.signature4) {
            files = try Self.readRar4(data)
        } else {
            throw ArchiveError.notAnArchive
        }
        self.files = files
        self.entries = files.enumerated().map { index, file in
            ArchiveEntry(path: file.path, uncompressedSize: UInt64(file.unpackedSize), compressedSize: UInt64(file.packedSize),
                         method: file.isStored ? 0 : (file.algorithm == .rar50 ? 50 : 29), offset: UInt64(index),
                         isDirectory: file.isDirectory, isEncrypted: file.isEncrypted)
        }
    }

    func data(for entry: ArchiveEntry) throws -> Data {
        let index = Int(entry.offset)
        guard files.indices.contains(index) else { throw ArchiveError.entryNotFound(entry.path) }
        let file = files[index]
        if file.isDirectory || file.unpackedSize == 0 { return Data() }
        if file.isEncrypted { throw ArchiveError.encrypted }
        if file.isSplit { throw ArchiveError.unsupportedCompression(0x51) }
        if let original = file.original {
            guard let target = files[..<index].lastIndex(where: { $0.path == original }) else { throw ArchiveError.corrupted }
            return try data(for: entries[target])
        }
        guard file.packedSize > 0, data.hasBytes(at: file.dataOffset, count: file.packedSize) else { throw ArchiveError.corrupted }
        if file.isStored {
            let stored = data.subdata(in: (data.startIndex + file.dataOffset)..<(data.startIndex + file.dataOffset + file.packedSize))
            try check(stored, file)
            return stored
        }
        guard let algorithm = file.algorithm else { throw ArchiveError.unsupportedCompression(15) }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache.data(for: "\(index)") { return cached }
        let start = runStart(of: index)
        let next = nextCompressed(after: index)
        // A file on its own: a fresh unpacker.
        if start == index, !(next < files.count && files[next].isSolid) {
            let unpacker = try RarUnpacker(algorithm: algorithm, dictionarySize: file.dictionarySize, dataSize: file.unpackedSize)
            let output = try unpack(file, with: unpacker, solid: false)
            try check(output, file)
            return output
        }
        // A solid run: carry on from where the unpacker stopped, or start the run again.
        if solidUnpacker == nil || solidRun != start || solidNext > index {
            var dictionary = 0, total = 0, member = start
            while member < files.count, member == start || files[member].isSolid {
                dictionary = max(dictionary, files[member].dictionarySize)
                total += files[member].unpackedSize
                member = nextCompressed(after: member)
            }
            solidUnpacker = try RarUnpacker(algorithm: algorithm, dictionarySize: dictionary, dataSize: total)
            solidRun = start
            solidNext = start
        }
        guard let unpacker = solidUnpacker else { throw ArchiveError.corrupted }
        while solidNext <= index {
            let position = solidNext
            let current = files[position]
            solidNext = nextCompressed(after: position)
            let output: Data
            do {
                output = try unpack(current, with: unpacker, solid: position != start)
                try check(output, current)
            } catch {
                solidUnpacker = nil
                throw error
            }
            cache.store(output, for: "\(position)")
            if position == index { return output }
        }
        throw ArchiveError.corrupted
    }

    private func unpack(_ file: FileItem, with unpacker: RarUnpacker, solid: Bool) throws -> Data {
        guard data.hasBytes(at: file.dataOffset, count: file.packedSize) else { throw ArchiveError.corrupted }
        let range = (data.startIndex + file.dataOffset)..<(data.startIndex + file.dataOffset + file.packedSize)
        return try data[range].withUnsafeBytes { packed in
            try unpacker.unpack(packed, size: file.unpackedSize, solid: solid)
        }
    }

    private func check(_ output: Data, _ file: FileItem) throws {
        if let crc = file.crc, CRC32.checksum(output) != crc { throw ArchiveError.corrupted }
    }

    /// The first file of the solid run `index` belongs to: back over the compressed files that continue the one before.
    private func runStart(of index: Int) -> Int {
        var start = index
        while files[start].isSolid {
            var previous = start - 1
            while previous >= 0, !files[previous].isPacked { previous -= 1 }
            guard previous >= 0 else { break }
            start = previous
        }
        return start
    }

    private func nextCompressed(after index: Int) -> Int {
        var next = index + 1
        while next < files.count, !files[next].isPacked { next += 1 }
        return next
    }

    // MARK: - RAR 1.5 to 4

    private static func readRar4(_ data: Data) throws -> [FileItem] {
        var files: [FileItem] = []
        var position = signature4.count
        var archiveIsSolid = false
        while data.hasBytes(at: position, count: 7) {
            let type = data[data.startIndex + position + 2]
            let flags = Int(data.readLE(position + 3, as: UInt16.self))
            let headerSize = Int(data.readLE(position + 5, as: UInt16.self))
            guard headerSize >= 7, data.hasBytes(at: position, count: headerSize) else { throw ArchiveError.corrupted }
            var addSize = 0
            if flags & 0x8000 != 0 || type == 0x74 {
                guard headerSize >= 11 else { throw ArchiveError.corrupted }
                addSize = Int(data.readLE(position + 7, as: UInt32.self))
            }
            switch type {
            case 0x73:
                // Archive header: encrypted headers can't be listed.
                if flags & 0x0080 != 0 { throw ArchiveError.encrypted }
                archiveIsSolid = flags & 0x0008 != 0
            case 0x74:
                guard headerSize >= 32 else { throw ArchiveError.corrupted }
                var packedSize = Int(data.readLE(position + 7, as: UInt32.self))
                var unpackedSize = Int(data.readLE(position + 11, as: UInt32.self))
                let crc = data.readLE(position + 16, as: UInt32.self)
                let version = Int(data[data.startIndex + position + 24])
                let method = Int(data[data.startIndex + position + 25])
                let nameSize = Int(data.readLE(position + 26, as: UInt16.self))
                var nameStart = position + 32
                if flags & 0x0100 != 0 {
                    guard headerSize >= 40 else { throw ArchiveError.corrupted }
                    packedSize |= Int(data.readLE(position + 32, as: UInt32.self)) << 32
                    unpackedSize |= Int(data.readLE(position + 36, as: UInt32.self)) << 32
                    addSize = packedSize
                    nameStart += 8
                }
                guard data.hasBytes(at: nameStart, count: nameSize) else { throw ArchiveError.corrupted }
                let nameBytes = [UInt8](data[(data.startIndex + nameStart)..<(data.startIndex + nameStart + nameSize)])
                let name = decodeName4(nameBytes, unicode: flags & 0x0200 != 0)
                let isDirectory = flags & 0x00E0 == 0x00E0
                var algorithm: RarUnpacker.Algorithm?
                switch version {
                case 29, 36: algorithm = .rar29
                default: algorithm = nil
                }
                files.append(FileItem(path: name.replacingOccurrences(of: "\\", with: "/"), dataOffset: position + headerSize,
                                      packedSize: packedSize, unpackedSize: unpackedSize, crc: crc, isStored: method == 0x30,
                                      algorithm: algorithm, dictionarySize: 0x10000 << ((flags >> 5) & 7),
                                      isSolid: archiveIsSolid && flags & 0x0010 != 0, isDirectory: isDirectory,
                                      isEncrypted: flags & 0x0004 != 0, isSplit: flags & 0x0003 != 0))
            case 0x7B:
                return files
            default:
                break
            }
            position += headerSize + addSize
        }
        return files
    }

    /// RAR 1.5 to 4 names: the local code page, or UTF-8, or (with the Unicode flag) an ASCII name followed by
    /// a compact encoding of its Unicode form.
    static func decodeName4(_ bytes: [UInt8], unicode: Bool) -> String {
        if unicode, let zero = bytes.firstIndex(of: 0) {
            let ascii = Array(bytes[..<zero])
            let encoded = Array(bytes[(zero + 1)...])
            var units: [UInt16] = []
            var position = 0
            guard !encoded.isEmpty else { return String(decoding: ascii, as: UTF8.self) }
            let highByte = UInt16(encoded[position])
            position += 1
            var flags: UInt8 = 0
            var flagBits = 0
            while position < encoded.count {
                if flagBits == 0 {
                    flags = encoded[position]
                    position += 1
                    flagBits = 8
                }
                switch flags >> 6 {
                case 0:
                    guard position < encoded.count else { break }
                    units.append(UInt16(encoded[position]))
                    position += 1
                case 1:
                    guard position < encoded.count else { break }
                    units.append(UInt16(encoded[position]) + highByte << 8)
                    position += 1
                case 2:
                    guard position + 1 < encoded.count else { position = encoded.count; break }
                    units.append(UInt16(encoded[position]) | UInt16(encoded[position + 1]) << 8)
                    position += 2
                default:
                    guard position < encoded.count else { break }
                    var length = Int(encoded[position])
                    position += 1
                    if length & 0x80 != 0 {
                        guard position < encoded.count else { break }
                        let correction = encoded[position]
                        position += 1
                        length = length & 0x7F + 2
                        for _ in 0..<length where units.count < ascii.count {
                            units.append(UInt16(ascii[units.count] &+ correction) + highByte << 8)
                        }
                    } else {
                        length += 2
                        for _ in 0..<length where units.count < ascii.count {
                            units.append(UInt16(ascii[units.count]))
                        }
                    }
                }
                flags <<= 2
                flagBits -= 2
            }
            return String(decoding: units, as: UTF16.self)
        }
        if let name = String(bytes: bytes, encoding: .utf8) { return name }
        return CP437.decode(Data(bytes))
    }

    // MARK: - RAR 5

    private struct Reader5 {
        let data: Data
        var position: Int

        mutating func vint() throws -> Int {
            var value = 0
            var shift = 0
            while true {
                guard data.hasBytes(at: position, count: 1), shift < 64 else { throw ArchiveError.corrupted }
                let byte = data[data.startIndex + position]
                position += 1
                value |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
        }

        mutating func uint32() throws -> UInt32 {
            guard data.hasBytes(at: position, count: 4) else { throw ArchiveError.corrupted }
            defer { position += 4 }
            return data.readLE(position, as: UInt32.self)
        }
    }

    private static func readRar5(_ data: Data) throws -> [FileItem] {
        var files: [FileItem] = []
        var reader = Reader5(data: data, position: signature5.count)
        while data.hasBytes(at: reader.position, count: 4) {
            reader.position += 4
            let headerSize = try reader.vint()
            let headerStart = reader.position
            guard headerSize > 0, data.hasBytes(at: headerStart, count: headerSize) else { throw ArchiveError.corrupted }
            let type = try reader.vint()
            let flags = try reader.vint()
            let extraSize = flags & 0x0001 != 0 ? try reader.vint() : 0
            let dataSize = flags & 0x0002 != 0 ? try reader.vint() : 0
            switch type {
            case 4:
                // Encrypted headers.
                throw ArchiveError.encrypted
            case 5:
                return files
            case 2:
                let fileFlags = try reader.vint()
                let unpackedSize = try reader.vint()
                _ = try reader.vint()
                if fileFlags & 0x0002 != 0 { _ = try reader.uint32() }
                let crc: UInt32? = fileFlags & 0x0004 != 0 ? try reader.uint32() : nil
                let compression = try reader.vint()
                _ = try reader.vint()
                let nameSize = try reader.vint()
                guard data.hasBytes(at: reader.position, count: nameSize) else { throw ArchiveError.corrupted }
                let name = String(decoding: data[(data.startIndex + reader.position)..<(data.startIndex + reader.position + nameSize)],
                                  as: UTF8.self)
                reader.position += nameSize
                // Extra records: encryption (1), and redirection (5) for hard links (4) and file copies (5), whose
                // target is a file earlier in the archive.
                var isEncrypted = false
                var original: String?
                let extraEnd = headerStart + headerSize
                var extra = extraEnd - extraSize
                while extra < extraEnd {
                    var record = Reader5(data: data, position: extra)
                    let size = try record.vint()
                    let recordStart = record.position
                    let recordType = try record.vint()
                    if recordType == 1 { isEncrypted = true }
                    if recordType == 5 {
                        let redirection = try record.vint()
                        _ = try record.vint()
                        let length = try record.vint()
                        if redirection == 4 || redirection == 5, data.hasBytes(at: record.position, count: length) {
                            original = String(decoding: data[(data.startIndex + record.position)..<(data.startIndex + record.position + length)],
                                              as: UTF8.self)
                        }
                    }
                    extra = recordStart + size
                }
                let version = compression & 0x3F
                let method = (compression >> 7) & 7
                files.append(FileItem(path: name, dataOffset: headerStart + headerSize, packedSize: dataSize,
                                      unpackedSize: unpackedSize, crc: crc, isStored: method == 0,
                                      algorithm: version == 0 ? .rar50 : nil,
                                      dictionarySize: 0x20000 << ((compression >> 10) & 0xF),
                                      isSolid: compression & 0x40 != 0, isDirectory: fileFlags & 0x0001 != 0,
                                      isEncrypted: isEncrypted, isSplit: flags & 0x0018 != 0, original: original))
            default:
                break
            }
            reader.position = headerStart + headerSize + dataSize
        }
        return files
    }
}
