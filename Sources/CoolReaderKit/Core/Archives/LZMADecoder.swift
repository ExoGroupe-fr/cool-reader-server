import Foundation

/// LZMA and LZMA2, the compression of 7-Zip archives (CB7), written from the format's specification: a range
/// decoder, adaptive bit models and a sliding dictionary. The output comes in order, as much as asked for at a
/// time, so the files of a solid 7-Zip folder can be read one after the other.
nonisolated struct LZMAProperties: Equatable {
    var lc: Int
    var lp: Int
    var pb: Int

    /// The properties byte of an LZMA stream or LZMA2 chunk: (pb × 5 + lp) × 9 + lc.
    init?(byte: UInt8) {
        var value = Int(byte)
        guard value < 9 * 5 * 5 else { return nil }
        lc = value % 9
        value /= 9
        lp = value % 5
        pb = value / 5
    }
}

nonisolated final class LZMADecoder {
    enum Mode {
        /// A 7-Zip "LZMA" coder: five property bytes, one range-coded stream.
        case lzma(LZMAProperties, dictionarySize: Int)
        /// A 7-Zip "LZMA2" coder: chunks of LZMA or stored data, each saying what it resets.
        case lzma2(dictionarySize: Int)
    }

    private let input: UnsafePointer<UInt8>
    private let inputEnd: Int
    private var inPos = 0
    private var overrun = false
    private let isLZMA2: Bool

    // Range decoder.
    private var range: UInt32 = 0xFFFF_FFFF
    private var code: UInt32 = 0

    // Dictionary: a ring buffer of the latest output.
    private let dictionary: UnsafeMutablePointer<UInt8>
    private let dictionarySize: Int
    private var dictionaryPos = 0
    private var dictionaryFull = false
    /// Bytes produced since the dictionary was last reset (its low bits pick probabilities).
    private var position = 0

    // Model.
    private var properties = LZMAProperties(byte: 0x5D)!
    private var state = 0
    private var rep0 = 0, rep1 = 0, rep2 = 0, rep3 = 0
    private var pendingLength = 0
    private let probabilities: UnsafeMutablePointer<UInt16>
    private var literals: UnsafeMutablePointer<UInt16>
    private var literalCount = 0

    // LZMA2 chunk being read.
    private var chunkLeft = 0
    private var chunkIsStored = false
    private var chunkInputEnd = 0
    private var needsDictionaryReset = true
    private var finished = false

    // Offsets of the models inside `probabilities`.
    private static let isMatch = 0
    private static let isRep = 192
    private static let isRepG0 = 204
    private static let isRepG1 = 216
    private static let isRepG2 = 228
    private static let isRep0Long = 240
    private static let posSlot = 432
    private static let posDecoders = 688
    private static let align = 816
    private static let lengths = 832
    private static let repLengths = 1346
    private static let count = 1860

    /// `input` must stay valid while the decoder is used; `outputSize` (when known) bounds the dictionary.
    init(mode: Mode, input: UnsafePointer<UInt8>, count: Int, outputSize: Int?) throws {
        self.input = input
        self.inputEnd = count
        var size: Int
        switch mode {
        case .lzma(let properties, let dictionarySize):
            isLZMA2 = false
            self.properties = properties
            size = dictionarySize
        case .lzma2(let dictionarySize):
            isLZMA2 = true
            size = dictionarySize
        }
        // A dictionary larger than the whole output is never used past the output's size.
        if let outputSize { size = min(size, max(outputSize, 1)) }
        size = max(size, 4096)
        guard size <= 1 << 30 else { throw ArchiveError.unsupportedCompression(0x21) }
        dictionarySize = size
        dictionary = .allocate(capacity: size)
        probabilities = .allocate(capacity: Self.count)
        literals = .allocate(capacity: 0x300)
        literalCount = 0x300
        if !isLZMA2 {
            try resetState()
            try startRangeDecoder(end: count)
        }
    }

    deinit {
        dictionary.deallocate()
        probabilities.deallocate()
        literals.deallocate()
    }

    /// Writes the next `count` bytes of the output to `output`.
    func read(into output: UnsafeMutablePointer<UInt8>, count: Int) throws {
        var written = 0
        while written < count {
            if isLZMA2 {
                if chunkLeft == 0 { try nextChunk() }
                let length = min(chunkLeft, count - written)
                if chunkIsStored {
                    guard inPos + length <= inputEnd else { throw ArchiveError.corrupted }
                    for i in 0..<length { put(input[inPos + i], output + written + i) }
                    inPos += length
                } else {
                    try decode(into: output + written, count: length)
                }
                chunkLeft -= length
                written += length
                if !chunkIsStored, chunkLeft == 0 {
                    // An LZMA chunk ends exactly at its packed size.
                    inPos = chunkInputEnd
                }
            } else {
                try decode(into: output + written, count: count - written)
                written = count
            }
        }
        if overrun { throw ArchiveError.corrupted }
    }

    // MARK: - LZMA2 chunks

    private func nextChunk() throws {
        guard !finished, inPos < inputEnd else { throw ArchiveError.corrupted }
        let control = Int(input[inPos])
        inPos += 1
        if control == 0 {
            finished = true
            throw ArchiveError.corrupted
        }
        guard inPos + 2 <= inputEnd else { throw ArchiveError.corrupted }
        if control == 1 || control == 2 {
            if control == 1 { resetDictionary() } else if needsDictionaryReset { throw ArchiveError.corrupted }
            chunkLeft = (Int(input[inPos]) << 8 | Int(input[inPos + 1])) + 1
            inPos += 2
            chunkIsStored = true
            return
        }
        guard control >= 0x80, inPos + 4 <= inputEnd else { throw ArchiveError.corrupted }
        chunkLeft = ((control & 0x1F) << 16 | Int(input[inPos]) << 8 | Int(input[inPos + 1])) + 1
        let packed = (Int(input[inPos + 2]) << 8 | Int(input[inPos + 3])) + 1
        inPos += 4
        let reset = (control >> 5) & 3
        if reset == 3 { resetDictionary() } else if needsDictionaryReset { throw ArchiveError.corrupted }
        if reset >= 2 {
            guard inPos < inputEnd, let properties = LZMAProperties(byte: input[inPos]),
                  properties.lc + properties.lp <= 4 else { throw ArchiveError.corrupted }
            inPos += 1
            self.properties = properties
        }
        if reset >= 1 { try resetState() }
        chunkIsStored = false
        chunkInputEnd = inPos + packed
        guard chunkInputEnd <= inputEnd else { throw ArchiveError.corrupted }
        try startRangeDecoder(end: chunkInputEnd)
    }

    private func resetDictionary() {
        dictionaryPos = 0
        dictionaryFull = false
        position = 0
        needsDictionaryReset = false
    }

    private func resetState() throws {
        let count = 0x300 << (properties.lc + properties.lp)
        if count != literalCount {
            literals.deallocate()
            literals = .allocate(capacity: count)
            literalCount = count
        }
        probabilities.initialize(repeating: 1024, count: Self.count)
        literals.initialize(repeating: 1024, count: count)
        state = 0
        rep0 = 0; rep1 = 0; rep2 = 0; rep3 = 0
        pendingLength = 0
    }

    private func startRangeDecoder(end: Int) throws {
        guard inPos + 5 <= end else { throw ArchiveError.corrupted }
        range = 0xFFFF_FFFF
        code = 0
        for i in 1...4 { code = code << 8 | UInt32(input[inPos + i]) }
        inPos += 5
    }

    // MARK: - Range decoder

    @inline(__always) private func normalize() {
        if range < 1 << 24 {
            range <<= 8
            if inPos < inputEnd {
                code = code << 8 | UInt32(input[inPos])
            } else {
                code <<= 8
                overrun = true
            }
            inPos += 1
        }
    }

    @inline(__always) private func bit(_ probability: UnsafeMutablePointer<UInt16>) -> Int {
        let value = UInt32(probability.pointee)
        let bound = (range >> 11) &* value
        if code < bound {
            probability.pointee = UInt16(value + ((2048 - value) >> 5))
            range = bound
            normalize()
            return 0
        }
        probability.pointee = UInt16(value - (value >> 5))
        code &-= bound
        range &-= bound
        normalize()
        return 1
    }

    @inline(__always) private func directBits(_ count: Int) -> Int {
        var result: UInt32 = 0
        for _ in 0..<count {
            range >>= 1
            code &-= range
            let mask = 0 &- (code >> 31)
            code &+= range & mask
            normalize()
            result = result << 1 &+ (mask &+ 1)
        }
        return Int(result)
    }

    @inline(__always) private func tree(_ models: UnsafeMutablePointer<UInt16>, bits: Int) -> Int {
        var m = 1
        for _ in 0..<bits { m = m << 1 + bit(models + m) }
        return m - 1 << bits
    }

    @inline(__always) private func reverseTree(_ models: UnsafeMutablePointer<UInt16>, bits: Int) -> Int {
        var m = 1, symbol = 0
        for i in 0..<bits {
            let b = bit(models + m)
            m = m << 1 + b
            symbol |= b << i
        }
        return symbol
    }

    @inline(__always) private func length(_ base: Int, posState: Int) -> Int {
        let models = probabilities + base
        if bit(models) == 0 { return tree(models + 2 + posState << 3, bits: 3) }
        if bit(models + 1) == 0 { return 8 + tree(models + 130 + posState << 3, bits: 3) }
        return 16 + tree(models + 258, bits: 8)
    }

    // MARK: - Output

    @inline(__always) private func put(_ byte: UInt8, _ output: UnsafeMutablePointer<UInt8>) {
        dictionary[dictionaryPos] = byte
        dictionaryPos += 1
        if dictionaryPos == dictionarySize {
            dictionaryPos = 0
            dictionaryFull = true
        }
        position &+= 1
        output.pointee = byte
    }

    /// The byte `distance` bytes back (1 = the last one).
    @inline(__always) private func byte(at distance: Int) -> UInt8 {
        let index = dictionaryPos - distance
        return dictionary[index >= 0 ? index : index + dictionarySize]
    }

    @inline(__always) private func isValid(distance: Int) -> Bool {
        distance <= dictionarySize && (dictionaryFull || distance <= dictionaryPos)
    }

    // MARK: - LZMA

    private func decode(into output: UnsafeMutablePointer<UInt8>, count: Int) throws {
        var produced = 0
        // A match cut short by the previous call.
        while pendingLength > 0, produced < count {
            put(byte(at: rep0 + 1), output + produced)
            produced += 1
            pendingLength -= 1
        }
        let pbMask = 1 << properties.pb - 1
        let lpMask = 1 << properties.lp - 1
        let lc = properties.lc
        while produced < count {
            let posState = position & pbMask
            if bit(probabilities + Self.isMatch + state << 4 + posState) == 0 {
                // A literal, guided by the byte at rep0 after a match.
                let previous = dictionaryFull || dictionaryPos > 0 ? Int(byte(at: 1)) : 0
                let models = literals + 0x300 * ((position & lpMask) << lc + previous >> (8 - lc))
                var symbol = 1
                if state >= 7 {
                    guard isValid(distance: rep0 + 1) else { throw ArchiveError.corrupted }
                    var matchByte = Int(byte(at: rep0 + 1))
                    repeat {
                        let matchBit = (matchByte >> 7) & 1
                        matchByte <<= 1
                        let b = bit(models + (1 + matchBit) << 8 + symbol)
                        symbol = symbol << 1 | b
                        if matchBit != b { break }
                    } while symbol < 0x100
                }
                while symbol < 0x100 { symbol = symbol << 1 | bit(models + symbol) }
                put(UInt8(truncatingIfNeeded: symbol), output + produced)
                produced += 1
                state = state < 4 ? 0 : (state < 10 ? state - 3 : state - 6)
                continue
            }
            var length: Int
            if bit(probabilities + Self.isRep + state) != 0 {
                guard dictionaryFull || dictionaryPos > 0 else { throw ArchiveError.corrupted }
                if bit(probabilities + Self.isRepG0 + state) == 0 {
                    if bit(probabilities + Self.isRep0Long + state << 4 + posState) == 0 {
                        // A single byte from rep0.
                        state = state < 7 ? 9 : 11
                        put(byte(at: rep0 + 1), output + produced)
                        produced += 1
                        continue
                    }
                } else {
                    let distance: Int
                    if bit(probabilities + Self.isRepG1 + state) == 0 {
                        distance = rep1
                    } else {
                        if bit(probabilities + Self.isRepG2 + state) == 0 {
                            distance = rep2
                        } else {
                            distance = rep3
                            rep3 = rep2
                        }
                        rep2 = rep1
                    }
                    rep1 = rep0
                    rep0 = distance
                }
                length = self.length(Self.repLengths, posState: posState)
                state = state < 7 ? 8 : 11
            } else {
                rep3 = rep2; rep2 = rep1; rep1 = rep0
                length = self.length(Self.lengths, posState: posState)
                state = state < 7 ? 7 : 10
                // The distance: a slot, then bits from models or direct.
                let slot = tree(probabilities + Self.posSlot + min(length, 3) << 6, bits: 6)
                if slot < 4 {
                    rep0 = slot
                } else {
                    let directCount = slot >> 1 - 1
                    var distance = (2 | slot & 1) << directCount
                    if slot < 14 {
                        distance += reverseTree(probabilities + Self.posDecoders + distance - slot, bits: directCount)
                    } else {
                        distance += directBits(directCount - 4) << 4
                        distance += reverseTree(probabilities + Self.align, bits: 4)
                    }
                    if distance == 0xFFFF_FFFF {
                        // The end marker: only valid exactly at the end.
                        throw ArchiveError.corrupted
                    }
                    rep0 = distance
                }
                guard isValid(distance: rep0 + 1) else { throw ArchiveError.corrupted }
            }
            length += 2
            let now = min(length, count - produced)
            for _ in 0..<now {
                put(byte(at: rep0 + 1), output + produced)
                produced += 1
            }
            pendingLength = length - now
        }
        if overrun { throw ArchiveError.corrupted }
    }
}
