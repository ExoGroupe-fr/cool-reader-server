import Foundation

/// Raw DEFLATE (RFC 1951), the compression of ZIP and some 7-Zip archives, decoded in Swift: the app uses
/// Apple's Compression framework, which Linux doesn't have. Huffman codes up to 9 bits come from a lookup
/// table, longer ones are decoded a bit at a time.
nonisolated enum Inflate {
    /// Decodes `input` into exactly `expectedSize` bytes.
    static func decode(_ input: UnsafeRawBufferPointer, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written = try output.withUnsafeMutableBytes { raw -> Int in
            var decoder = Decoder(input: input, output: raw.bindMemory(to: UInt8.self))
            try decoder.run()
            return decoder.written
        }
        guard written == expectedSize else { throw ArchiveError.corrupted }
        return output
    }

    fileprivate static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
                                         131, 163, 195, 227, 258]
    fileprivate static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    fileprivate static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
                                           2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    fileprivate static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12,
                                            13, 13]
    /// The order in which a dynamic block lists the lengths of its code-length code.
    fileprivate static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    fileprivate static let fixedLiterals: Huffman = {
        var lengths = [UInt8](repeating: 8, count: 288)
        for symbol in 144..<256 { lengths[symbol] = 9 }
        for symbol in 256..<280 { lengths[symbol] = 7 }
        return try! Huffman(lengths: lengths)
    }()
    fileprivate static let fixedDistances = try! Huffman(lengths: [UInt8](repeating: 5, count: 30))
}

/// A canonical Huffman code: symbols ordered by code, and a table for the short codes.
nonisolated private struct Huffman: Sendable {
    static let fastBits = 9
    var counts = [Int](repeating: 0, count: 16)
    var symbols: [Int]
    /// Indexed by the next `fastBits` bits of the stream: `length << 16 | symbol`, or -1 for a longer code.
    var fast: [Int32]

    init(lengths: [UInt8]) throws {
        for length in lengths { counts[Int(length)] += 1 }
        counts[0] = 0
        var left = 1
        for length in 1...15 {
            left = left << 1 - counts[length]
            guard left >= 0 else { throw ArchiveError.corrupted }
        }
        var offsets = [Int](repeating: 0, count: 16)
        for length in 1..<15 { offsets[length + 1] = offsets[length] + counts[length] }
        symbols = [Int](repeating: 0, count: lengths.count)
        for (symbol, length) in lengths.enumerated() where length != 0 {
            symbols[offsets[Int(length)]] = symbol
            offsets[Int(length)] += 1
        }
        fast = [Int32](repeating: -1, count: 1 << Self.fastBits)
        var code = 0, index = 0
        for length in 1...15 {
            for _ in 0..<counts[length] {
                if length <= Self.fastBits {
                    // The stream holds codes most significant bit first.
                    var reversed = 0
                    for bit in 0..<length where code & (1 << bit) != 0 { reversed |= 1 << (length - 1 - bit) }
                    var slot = reversed
                    while slot < 1 << Self.fastBits {
                        fast[slot] = Int32(length << 16 | symbols[index])
                        slot += 1 << length
                    }
                }
                code += 1
                index += 1
            }
            code <<= 1
        }
    }
}

nonisolated private struct Decoder {
    let input: UnsafeRawBufferPointer
    let output: UnsafeMutableBufferPointer<UInt8>
    var position = 0
    var bitBuffer: UInt64 = 0
    var bitCount = 0
    var written = 0

    /// Fills the bit buffer past 56 bits; past the end of the input it adds zeros, which `checkInput` catches.
    @inline(__always) mutating func refill() {
        while bitCount <= 56 {
            let byte: UInt64 = position < input.count ? UInt64(input[position]) : 0
            position += 1
            bitBuffer |= byte << UInt64(bitCount)
            bitCount += 8
        }
    }

    @inline(__always) mutating func bits(_ count: Int) -> Int {
        if bitCount < count { refill() }
        let value = Int(truncatingIfNeeded: bitBuffer & ((1 << UInt64(count)) - 1))
        bitBuffer >>= UInt64(count)
        bitCount -= count
        return value
    }

    /// The stream may not use more bits than the input holds.
    @inline(__always) func checkInput() throws {
        if position * 8 - bitCount > input.count * 8 { throw ArchiveError.corrupted }
    }

    @inline(__always) mutating func decode(_ code: Huffman) throws -> Int {
        if bitCount < 16 { refill() }
        let entry = code.fast[Int(truncatingIfNeeded: bitBuffer) & ((1 << Huffman.fastBits) - 1)]
        if entry >= 0 {
            let length = Int(entry >> 16)
            bitBuffer >>= UInt64(length)
            bitCount -= length
            return Int(entry & 0xFFFF)
        }
        var value = 0, first = 0, index = 0
        for length in 1...15 {
            value |= Int(bitBuffer & 1)
            bitBuffer >>= 1
            bitCount -= 1
            let count = code.counts[length]
            if value - first < count { return code.symbols[index + value - first] }
            index += count
            first = (first + count) << 1
            value <<= 1
        }
        throw ArchiveError.corrupted
    }

    mutating func run() throws {
        var isLast = false
        while !isLast {
            isLast = bits(1) == 1
            switch bits(2) {
            case 0: try stored()
            case 1: try codes(Inflate.fixedLiterals, Inflate.fixedDistances)
            case 2:
                let (literals, distances) = try dynamicCodes()
                try codes(literals, distances)
            default: throw ArchiveError.corrupted
            }
            try checkInput()
        }
    }

    mutating func stored() throws {
        let partial = bitCount & 7
        bitBuffer >>= UInt64(partial)
        bitCount -= partial
        let length = bits(16), complement = bits(16)
        guard length == ~complement & 0xFFFF, written + length <= output.count else { throw ArchiveError.corrupted }
        var remaining = length
        while remaining > 0, bitCount >= 8 {
            output[written] = UInt8(truncatingIfNeeded: bitBuffer)
            bitBuffer >>= 8
            bitCount -= 8
            written += 1
            remaining -= 1
        }
        if remaining > 0 {
            guard position + remaining <= input.count, let source = input.baseAddress, let target = output.baseAddress else {
                throw ArchiveError.corrupted
            }
            (target + written).update(from: source.advanced(by: position).assumingMemoryBound(to: UInt8.self), count: remaining)
            position += remaining
            written += remaining
        }
    }

    mutating func dynamicCodes() throws -> (Huffman, Huffman) {
        let literalCount = bits(5) + 257, distanceCount = bits(5) + 1, lengthCount = bits(4) + 4
        guard literalCount <= 286, distanceCount <= 30 else { throw ArchiveError.corrupted }
        var codeLengths = [UInt8](repeating: 0, count: 19)
        for index in 0..<lengthCount { codeLengths[Inflate.codeLengthOrder[index]] = UInt8(bits(3)) }
        let lengthCode = try Huffman(lengths: codeLengths)
        var lengths = [UInt8](repeating: 0, count: literalCount + distanceCount)
        var index = 0
        while index < lengths.count {
            let symbol = try decode(lengthCode)
            if symbol < 16 {
                lengths[index] = UInt8(symbol)
                index += 1
                continue
            }
            var value: UInt8 = 0
            let repeats: Int
            switch symbol {
            case 16:
                guard index > 0 else { throw ArchiveError.corrupted }
                value = lengths[index - 1]
                repeats = 3 + bits(2)
            case 17: repeats = 3 + bits(3)
            default: repeats = 11 + bits(7)
            }
            guard index + repeats <= lengths.count else { throw ArchiveError.corrupted }
            for _ in 0..<repeats {
                lengths[index] = value
                index += 1
            }
            try checkInput()
        }
        // A block must be able to end.
        guard lengths[256] != 0 else { throw ArchiveError.corrupted }
        return (try Huffman(lengths: Array(lengths[..<literalCount])), try Huffman(lengths: Array(lengths[literalCount...])))
    }

    mutating func codes(_ literals: Huffman, _ distances: Huffman) throws {
        while true {
            let symbol = try decode(literals)
            if symbol < 256 {
                guard written < output.count else { throw ArchiveError.corrupted }
                output[written] = UInt8(symbol)
                written += 1
            } else if symbol == 256 {
                return
            } else {
                let lengthIndex = symbol - 257
                guard lengthIndex < 29 else { throw ArchiveError.corrupted }
                let length = Inflate.lengthBase[lengthIndex] + bits(Inflate.lengthExtra[lengthIndex])
                let distanceSymbol = try decode(distances)
                guard distanceSymbol < 30 else { throw ArchiveError.corrupted }
                let distance = Inflate.distanceBase[distanceSymbol] + bits(Inflate.distanceExtra[distanceSymbol])
                guard distance <= written, written + length <= output.count else { throw ArchiveError.corrupted }
                var from = written - distance
                for _ in 0..<length {
                    output[written] = output[from]
                    written += 1
                    from += 1
                }
            }
            try checkInput()
        }
    }
}
