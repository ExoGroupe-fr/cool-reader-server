import Foundation

/// A file stored inside an archive (ZIP, TAR…).
nonisolated struct ArchiveEntry: Sendable, Hashable {
    /// Path inside the archive, with `/` separators.
    let path: String
    let uncompressedSize: UInt64
    let compressedSize: UInt64
    /// ZIP compression method (0 = stored, 8 = deflate). Always 0 for TAR.
    let method: UInt16
    /// Offset of the entry's header (ZIP local header, TAR header) or of its data.
    let offset: UInt64
    let isDirectory: Bool
    let isEncrypted: Bool

    var fileName: String { (path as NSString).lastPathComponent }
    var pathExtension: String { (path as NSString).pathExtension.lowercased() }
}

nonisolated enum ArchiveError: LocalizedError, Equatable {
    case notAnArchive
    case corrupted
    case unsupportedCompression(UInt16)
    case encrypted
    case entryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notAnArchive: "This file isn't an archive that can be read."
        case .corrupted: "The archive seems damaged."
        case .unsupportedCompression(let method): "Unsupported compression method (\(method))."
        case .encrypted: "Password-protected archives aren't supported."
        case .entryNotFound(let path): "File not found in the archive: \(path)"
        }
    }
}

/// Random access to the files of an archive. Implementations are immutable after creation and safe to use from any thread.
nonisolated protocol ArchiveReader: AnyObject, Sendable {
    var entries: [ArchiveEntry] { get }
    func data(for entry: ArchiveEntry) throws -> Data
}

nonisolated extension ArchiveReader {
    func entry(atPath path: String) -> ArchiveEntry? {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return entries.first { $0.path == normalized }
            ?? entries.first { $0.path.caseInsensitiveCompare(normalized) == .orderedSame }
    }

    func data(atPath path: String) throws -> Data {
        guard let entry = entry(atPath: path) else { throw ArchiveError.entryNotFound(path) }
        return try data(for: entry)
    }
}

nonisolated extension Data {
    /// Reads a little-endian integer at `offset` (relative to `startIndex`). The caller checks bounds.
    @inline(__always)
    func readLE<T: FixedWidthInteger>(_ offset: Int, as type: T.Type = T.self) -> T {
        withUnsafeBytes { raw in
            T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self))
        }
    }

    func hasBytes(at offset: Int, count: Int) -> Bool {
        offset >= 0 && count >= 0 && offset <= self.count - count
    }
}
