import Foundation

/// A DNS message (RFC 1035) with the two bits Multicast DNS adds (RFC 6762 §18): a question's unicast-response bit
/// and a record's cache-flush bit. Names are compressed when written and followed through their pointers when read;
/// anything malformed throws, so a bad packet is dropped whole.
nonisolated struct DNSMessage: Equatable, Sendable {
    var id: UInt16 = 0
    var flags: UInt16 = 0
    var questions: [Question] = []
    var answers: [Record] = []
    var authorities: [Record] = []
    var additionals: [Record] = []

    /// A response with authority: the flags of every mDNS response.
    static let responseFlags: UInt16 = 0x8400

    var isResponse: Bool { flags & 0x8000 != 0 }
    var opcode: UInt16 { (flags >> 11) & 0xF }
    var responseCode: UInt16 { flags & 0xF }

    nonisolated struct FormatError: Error {}

    /// The record types this code reads; the others stay raw bytes.
    nonisolated enum RecordType {
        static let a: UInt16 = 1
        static let ptr: UInt16 = 12
        static let txt: UInt16 = 16
        static let aaaa: UInt16 = 28
        static let srv: UInt16 = 33
        static let any: UInt16 = 255
    }

    /// A domain name as its labels, so an instance label keeps its dots and spaces ("Cool Reader Server"). Names
    /// compare without regard to ASCII case, as in DNS.
    nonisolated struct Name: Hashable, Sendable, CustomStringConvertible {
        let labels: [String]

        init(_ labels: [String]) {
            self.labels = labels.filter { !$0.isEmpty }
        }

        init(dotted: String) {
            self.init(dotted.split(separator: ".").map(String.init))
        }

        /// The labels with their ASCII letters lowercased: what comparisons and compression go by.
        var key: [String] {
            labels.map { (label: String) -> String in
                String(decoding: label.utf8.map { (byte: UInt8) -> UInt8 in (65...90).contains(byte) ? byte + 32 : byte }, as: UTF8.self)
            }
        }

        var description: String { labels.joined(separator: ".") + "." }

        static func == (lhs: Name, rhs: Name) -> Bool { lhs.key == rhs.key }

        func hash(into hasher: inout Hasher) { hasher.combine(key) }

        /// `text` shortened to fit a label's 63 bytes with `suffix` kept whole: "Cool Reader Server (2)".
        static func label(_ text: String, suffix: String = "") -> String {
            var text = text
            while !text.isEmpty, text.utf8.count + suffix.utf8.count > 63 { text.removeLast() }
            return text + suffix
        }
    }

    nonisolated struct Question: Equatable, Sendable {
        var name: Name
        var type: UInt16
        /// mDNS "QU": the querier would rather have the answer by unicast.
        var unicastResponse = false
        var recordClass: UInt16 = 1
    }

    nonisolated struct Record: Hashable, Sendable {
        var name: Name
        var ttl: UInt32
        var data: RecordData
        /// mDNS: the record replaces what caches hold for its name and type. Set on records only one host owns.
        var cacheFlush = false
        var recordClass: UInt16 = 1

        var type: UInt16 { data.type }

        /// The same record, whatever its TTL and cache-flush bit.
        func isSame(as other: Record) -> Bool {
            name == other.name && data == other.data && recordClass == other.recordClass
        }
    }

    nonisolated enum RecordData: Hashable, Sendable {
        case a([UInt8])
        case ptr(Name)
        case txt([String])
        case srv(priority: UInt16, weight: UInt16, port: UInt16, target: Name)
        /// Any other type, as its raw bytes.
        case other(type: UInt16, bytes: [UInt8])

        var type: UInt16 {
            switch self {
            case .a: RecordType.a
            case .ptr: RecordType.ptr
            case .txt: RecordType.txt
            case .srv: RecordType.srv
            case .other(let type, _): type
            }
        }
    }

    /// The message on the wire. Additional records that would take it past `limit` bytes are left out, the last
    /// first, so a reply fits in one Ethernet frame (RFC 6762 §17).
    func encoded(limit: Int = 9000) -> [UInt8] {
        var message = self
        while true {
            var writer = Writer()
            writer.write(message)
            if writer.bytes.count <= limit || message.additionals.isEmpty { return writer.bytes }
            message.additionals.removeLast()
        }
    }

    /// A DNS-SD TXT record's strings: "key=value", sorted so the record reads the same at every start.
    static func txtStrings(_ pairs: [String: String]) -> [String] {
        pairs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    /// TXT strings as they go on the wire, each after its length byte, which is also what dns_sd takes. An empty
    /// record is one empty string (RFC 6763 §6.1).
    static func txtData(_ strings: [String]) -> [UInt8] {
        var bytes: [UInt8] = []
        for string in strings.isEmpty ? [""] : strings {
            let utf8 = Array(string.utf8.prefix(255))
            bytes.append(UInt8(utf8.count))
            bytes += utf8
        }
        return bytes
    }

    private nonisolated struct Writer {
        var bytes: [UInt8] = []
        /// Where each name suffix already written starts, for compression pointers.
        private var suffixes: [[String]: Int] = [:]

        mutating func write(_ message: DNSMessage) {
            u16(message.id)
            u16(message.flags)
            for count in [message.questions.count, message.answers.count, message.authorities.count, message.additionals.count] {
                u16(UInt16(count))
            }
            for question in message.questions {
                name(question.name)
                u16(question.type)
                u16(question.recordClass | (question.unicastResponse ? 0x8000 : 0))
            }
            for record in message.answers + message.authorities + message.additionals { write(record) }
        }

        mutating func write(_ record: Record) {
            name(record.name)
            u16(record.type)
            u16(record.recordClass | (record.cacheFlush ? 0x8000 : 0))
            u32(record.ttl)
            let lengthOffset = bytes.count
            u16(0)
            switch record.data {
            case .a(let address): bytes += address
            case .ptr(let target): name(target)
            case .txt(let strings): bytes += DNSMessage.txtData(strings)
            case .srv(let priority, let weight, let port, let target):
                u16(priority)
                u16(weight)
                u16(port)
                // Not compressed: RFC 2782 forbids it, and legacy unicast replies go to plain DNS resolvers.
                name(target, compress: false)
            case .other(_, let data): bytes += data
            }
            let length = bytes.count - lengthOffset - 2
            bytes[lengthOffset] = UInt8(truncatingIfNeeded: length >> 8)
            bytes[lengthOffset + 1] = UInt8(truncatingIfNeeded: length)
        }

        /// A name, or the part of it not written yet followed by a pointer to the rest.
        mutating func name(_ name: Name, compress: Bool = true) {
            let keys = name.key
            for index in name.labels.indices {
                let suffix = Array(keys[index...])
                if compress, let offset = suffixes[suffix] {
                    u16(0xC000 | UInt16(offset))
                    return
                }
                if bytes.count < 0x4000, suffixes[suffix] == nil { suffixes[suffix] = bytes.count }
                let label = Array(name.labels[index].utf8.prefix(63))
                bytes.append(UInt8(label.count))
                bytes += label
            }
            bytes.append(0)
        }

        mutating func u16(_ value: UInt16) {
            bytes.append(UInt8(value >> 8))
            bytes.append(UInt8(value & 0xFF))
        }

        mutating func u32(_ value: UInt32) {
            u16(UInt16(value >> 16))
            u16(UInt16(value & 0xFFFF))
        }
    }

    private nonisolated struct Reader {
        let bytes: [UInt8]
        var position = 0

        mutating func question() throws -> Question {
            let name = try self.name()
            let type = try u16()
            let rawClass = try u16()
            return Question(name: name, type: type, unicastResponse: rawClass & 0x8000 != 0, recordClass: rawClass & 0x7FFF)
        }

        mutating func record() throws -> Record {
            let name = try self.name()
            let type = try u16()
            let rawClass = try u16()
            let ttl = try u32()
            let length = Int(try u16())
            let start = position, end = position + length
            guard end <= bytes.count else { throw FormatError() }
            let data: RecordData
            switch type {
            case RecordType.a where length == 4:
                data = .a(Array(bytes[start..<end]))
            case RecordType.ptr:
                data = .ptr(try self.name())
            case RecordType.srv:
                let priority = try u16(), weight = try u16(), port = try u16()
                data = .srv(priority: priority, weight: weight, port: port, target: try self.name())
            case RecordType.txt:
                var strings: [String] = []
                var cursor = start
                while cursor < end {
                    let count = Int(bytes[cursor])
                    guard cursor + 1 + count <= end else { throw FormatError() }
                    strings.append(String(decoding: bytes[(cursor + 1)..<(cursor + 1 + count)], as: UTF8.self))
                    cursor += 1 + count
                }
                data = .txt(strings)
            default:
                data = .other(type: type, bytes: Array(bytes[start..<end]))
            }
            guard position <= end else { throw FormatError() }
            position = end
            return Record(name: name, ttl: ttl, data: data, cacheFlush: rawClass & 0x8000 != 0, recordClass: rawClass & 0x7FFF)
        }

        /// A name, through its compression pointers. Each pointer must go back before the stretch it ends, so a
        /// loop can't be followed forever.
        mutating func name() throws -> Name {
            var labels: [String] = []
            var cursor = position
            var limit = position
            var resume: Int?
            var length = 0
            while true {
                guard cursor < bytes.count else { throw FormatError() }
                let byte = bytes[cursor]
                if byte == 0 {
                    cursor += 1
                    break
                }
                switch byte & 0xC0 {
                case 0x00:
                    let count = Int(byte)
                    length += count + 1
                    guard cursor + 1 + count <= bytes.count, length <= 255 else { throw FormatError() }
                    labels.append(String(decoding: bytes[(cursor + 1)..<(cursor + 1 + count)], as: UTF8.self))
                    cursor += 1 + count
                case 0xC0:
                    guard cursor + 1 < bytes.count else { throw FormatError() }
                    let target = Int(byte & 0x3F) << 8 | Int(bytes[cursor + 1])
                    guard target < limit else { throw FormatError() }
                    if resume == nil { resume = cursor + 2 }
                    limit = target
                    cursor = target
                default:
                    throw FormatError()
                }
            }
            position = resume ?? cursor
            return Name(labels)
        }

        mutating func u8() throws -> UInt8 {
            guard position < bytes.count else { throw FormatError() }
            position += 1
            return bytes[position - 1]
        }

        mutating func u16() throws -> UInt16 {
            let high = try u8()
            let low = try u8()
            return UInt16(high) << 8 | UInt16(low)
        }

        mutating func u32() throws -> UInt32 {
            let high = try u16()
            let low = try u16()
            return UInt32(high) << 16 | UInt32(low)
        }
    }
}

nonisolated extension DNSMessage {
    /// Reads a message off the wire.
    init(bytes: [UInt8]) throws {
        var reader = Reader(bytes: bytes)
        id = try reader.u16()
        flags = try reader.u16()
        let questionCount = try reader.u16(), answerCount = try reader.u16()
        let authorityCount = try reader.u16(), additionalCount = try reader.u16()
        for _ in 0..<questionCount { questions.append(try reader.question()) }
        for _ in 0..<answerCount { answers.append(try reader.record()) }
        for _ in 0..<authorityCount { authorities.append(try reader.record()) }
        for _ in 0..<additionalCount { additionals.append(try reader.record()) }
    }
}
