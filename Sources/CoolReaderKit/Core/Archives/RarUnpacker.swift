import Foundation

/// RAR's LZ compression, written from its published decompression source: version 2.9 (RAR 3 and 4 archives,
/// with their standard filters) and version 5.0 (RAR 5). Text blocks compressed with PPMd (RAR 3 and 4) aren't
/// read. One unpacker decodes the files of a solid run one after the other, keeping its window and tables.
nonisolated final class RarUnpacker {
    enum Algorithm { case rar29, rar50 }

    private let algorithm: Algorithm
    private let window: UnsafeMutablePointer<UInt8>
    private let windowSize: Int
    private let mask: Int
    private var unpPtr = 0
    private var wrPtr = 0
    private var writeBorder = 0

    // The packed data of the file being decoded, with zeros past its end.
    private var input: UnsafeMutablePointer<UInt8>
    private var inputCapacity = 0
    private var inputSize = 0
    private var inAddr = 0
    private var inBit = 0

    // The file being produced.
    private var output: UnsafeMutablePointer<UInt8>?
    private var outputSize = 0
    private var filled = 0
    /// Bytes produced for this file so far, filters' offsets included.
    private var written = 0

    // LZ state kept through a solid run.
    private var oldDist = [Int](repeating: 0, count: 4)
    private var lastLength = 0
    private var tablesRead = false
    private let ld = HuffmanTable(), dd = HuffmanTable(), ldd = HuffmanTable(), rd = HuffmanTable(), bd = HuffmanTable()

    // RAR 2.9.
    private var oldTable = [UInt8](repeating: 0, count: 404)
    private var prevLowDist = 0
    private var lowDistRepCount = 0
    private var isPPMBlock = false
    private var filterTypes30: [StandardFilter] = []
    private var oldFilterLengths: [Int] = []
    private var stack30: [Filter30?] = []
    private var lastFilter = 0
    private let vmMemory: UnsafeMutablePointer<UInt8>

    // RAR 5.
    private var filters50: [Filter50] = []
    private var blockStart = 0
    private var blockSize = -1
    private var blockBitSize = 0
    private var lastBlockInFile = false
    private var tablePresent = false

    private static let vmMemorySize = 0x40000

    init(algorithm: Algorithm, dictionarySize: Int, dataSize: Int) throws {
        self.algorithm = algorithm
        // The window never needs to exceed the data it serves; it stays a power of two.
        var size = 1 << 18
        while size < min(dictionarySize, dataSize) { size <<= 1 }
        guard size <= 1 << 30 else { throw ArchiveError.unsupportedCompression(50) }
        windowSize = size
        mask = size - 1
        window = .allocate(capacity: size)
        window.initialize(repeating: 0, count: size)
        input = .allocate(capacity: 1)
        vmMemory = .allocate(capacity: Self.vmMemorySize + 8)
        vmMemory.initialize(repeating: 0, count: Self.vmMemorySize + 8)
    }

    deinit {
        window.deallocate()
        input.deallocate()
        vmMemory.deallocate()
    }

    /// Decodes one file. `solid` continues from the previous file of the run.
    func unpack(_ packed: UnsafeRawBufferPointer, size: Int, solid: Bool) throws -> Data {
        if packed.count + 64 > inputCapacity {
            input.deallocate()
            inputCapacity = packed.count + 64
            input = .allocate(capacity: inputCapacity)
        }
        input.initialize(repeating: 0, count: inputCapacity)
        if let base = packed.baseAddress { input.update(from: base.assumingMemoryBound(to: UInt8.self), count: packed.count) }
        inputSize = packed.count
        inAddr = 0
        inBit = 0
        var result = Data(count: size)
        try result.withUnsafeMutableBytes { raw in
            output = raw.bindMemory(to: UInt8.self).baseAddress
            outputSize = size
            filled = 0
            written = 0
            defer { output = nil }
            initData(solid: solid)
            switch algorithm {
            case .rar29: try unpack29(solid: solid)
            case .rar50: try unpack50(solid: solid)
            }
        }
        guard filled == size else { throw ArchiveError.corrupted }
        return result
    }

    private func initData(solid: Bool) {
        if !solid {
            oldDist = [0, 0, 0, 0]
            lastLength = 0
            unpPtr = 0
            wrPtr = 0
            writeBorder = min(windowSize, 0x400000) & mask
            tablesRead = false
            oldTable = [UInt8](repeating: 0, count: 404)
            isPPMBlock = false
            filterTypes30 = []
            oldFilterLengths = []
            lastFilter = 0
        }
        // Filters never run across files.
        filters50 = []
        stack30 = []
        blockStart = 0
        blockSize = -1
        blockBitSize = 0
        lastBlockInFile = false
        tablePresent = false
    }

    // MARK: - Bits

    @inline(__always) private func getbits() -> Int {
        let value = Int(input[inAddr]) << 16 | Int(input[inAddr + 1]) << 8 | Int(input[inAddr + 2])
        return (value >> (8 - inBit)) & 0xFFFF
    }

    @inline(__always) private func getbits32() -> Int {
        var value = UInt32(input[inAddr]) << 24 | UInt32(input[inAddr + 1]) << 16 | UInt32(input[inAddr + 2]) << 8
            | UInt32(input[inAddr + 3])
        value <<= UInt32(inBit)
        value |= UInt32(input[inAddr + 4]) >> UInt32(8 - inBit)
        return Int(value)
    }

    @inline(__always) private func addbits(_ count: Int) {
        let bits = count + inBit
        inAddr += bits >> 3
        inBit = bits & 7
    }

    private var inputExhausted: Bool { inAddr > inputSize + 8 }

    @inline(__always) private func decode(_ table: HuffmanTable) -> Int {
        let field = getbits() & 0xFFFE
        if field < table.decodeLen[table.quickBits] {
            let code = field >> (16 - table.quickBits)
            addbits(Int(table.quickLen[code]))
            return Int(table.quickNum[code])
        }
        var bits = 15
        for length in (table.quickBits + 1)..<15 where field < table.decodeLen[length] {
            bits = length
            break
        }
        addbits(bits)
        let distance = (field - table.decodeLen[bits - 1]) >> (16 - bits)
        var position = table.decodePos[bits] + distance
        if position >= table.maxNumber { position = 0 }
        return Int(table.decodeNum[position])
    }

    /// The bit lengths of the 20 codes that encode the main tables' lengths.
    private func readBitLengths() -> [UInt8] {
        var lengths = [UInt8](repeating: 0, count: 20)
        var index = 0
        while index < 20 {
            let length = getbits() >> 12
            addbits(4)
            if length == 15 {
                var zeros = getbits() >> 12
                addbits(4)
                if zeros == 0 {
                    lengths[index] = 15
                    index += 1
                } else {
                    zeros += 2
                    while zeros > 0, index < 20 {
                        lengths[index] = 0
                        index += 1
                        zeros -= 1
                    }
                }
            } else {
                lengths[index] = UInt8(length)
                index += 1
            }
        }
        return lengths
    }

    /// The main tables' lengths, coded with `bd` (with the previous values added for RAR 2.9).
    private func readTableLengths(count: Int, previous: [UInt8]?) throws -> [UInt8] {
        var table = [UInt8](repeating: 0, count: count)
        var index = 0
        while index < count {
            if inputExhausted { throw ArchiveError.corrupted }
            let number = decode(bd)
            if number < 16 {
                table[index] = previous.map { UInt8((Int($0[index]) + number) & 0xF) } ?? UInt8(number)
                index += 1
            } else if number < 18 {
                var repeats: Int
                if number == 16 {
                    repeats = getbits() >> 13 + 3
                    addbits(3)
                } else {
                    repeats = getbits() >> 9 + 11
                    addbits(7)
                }
                guard index > 0 else { throw ArchiveError.corrupted }
                while repeats > 0, index < count {
                    table[index] = table[index - 1]
                    index += 1
                    repeats -= 1
                }
            } else {
                var zeros: Int
                if number == 18 {
                    zeros = getbits() >> 13 + 3
                    addbits(3)
                } else {
                    zeros = getbits() >> 9 + 11
                    addbits(7)
                }
                while zeros > 0, index < count {
                    table[index] = 0
                    index += 1
                    zeros -= 1
                }
            }
        }
        return table
    }

    // MARK: - Window

    @inline(__always) private func copyString(length: Int, distance: Int) {
        var source = unpPtr - distance
        for _ in 0..<length {
            window[unpPtr] = window[source & mask]
            unpPtr = (unpPtr + 1) & mask
            source += 1
        }
    }

    @inline(__always) private func insertOldDist(_ distance: Int) {
        oldDist[3] = oldDist[2]
        oldDist[2] = oldDist[1]
        oldDist[1] = oldDist[0]
        oldDist[0] = distance
    }

    private func writeData(_ data: UnsafePointer<UInt8>, _ count: Int) {
        if let output, filled < outputSize {
            let now = min(count, outputSize - filled)
            (output + filled).update(from: data, count: now)
            filled += now
        }
        written += count
    }

    private func writeArea(from start: Int, to end: Int) {
        if end < start {
            writeData(window + start, windowSize - start)
            writeData(window, end)
        } else if end > start {
            writeData(window + start, end - start)
        }
    }

    // MARK: - RAR 2.9

    private static let lengthBase: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112,
                                           128, 160, 192, 224]
    private static let lengthBits: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5]
    private static let (distanceBase30, distanceBits30): ([Int], [Int]) = {
        var bases: [Int] = [], bits: [Int] = []
        var distance = 0
        for (bitLength, count) in [4, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 14, 0, 12].enumerated() {
            for _ in 0..<count {
                bases.append(distance)
                bits.append(bitLength)
                distance += 1 << bitLength
            }
        }
        return (bases, bits)
    }()
    private static let shortBase: [Int] = [0, 4, 8, 16, 32, 64, 128, 192]
    private static let shortBits: [Int] = [2, 2, 3, 4, 5, 6, 6, 6]

    private func readTables30() throws {
        // Tables start on a byte boundary.
        addbits((8 - inBit) & 7)
        let field = getbits()
        if field & 0x8000 != 0 {
            isPPMBlock = true
            throw ArchiveError.unsupportedCompression(0x50)
        }
        isPPMBlock = false
        prevLowDist = 0
        lowDistRepCount = 0
        if field & 0x4000 == 0 { oldTable = [UInt8](repeating: 0, count: 404) }
        addbits(2)
        bd.build(readBitLengths(), size: 20)
        let table = try readTableLengths(count: 404, previous: oldTable)
        tablesRead = true
        ld.build(Array(table[0..<299]), size: 299)
        dd.build(Array(table[299..<359]), size: 60)
        ldd.build(Array(table[359..<376]), size: 17)
        rd.build(Array(table[376..<404]), size: 28)
        oldTable = table
    }

    /// The end of a block: a new table, or the end of the file.
    private func readEndOfBlock30() throws -> Bool {
        let field = getbits()
        var newTable: Bool, newFile = false
        if field & 0x8000 != 0 {
            newTable = true
            addbits(1)
        } else {
            newFile = true
            newTable = field & 0x4000 != 0
            addbits(2)
        }
        tablesRead = !newTable
        if newFile { return false }
        try readTables30()
        return true
    }

    private func unpack29(solid: Bool) throws {
        if !solid || !tablesRead { try readTables30() }
        while true {
            unpPtr &= mask
            if inputExhausted { break }
            if (wrPtr - unpPtr) & mask <= 0x101 + 3, wrPtr != unpPtr {
                try writeBuffer30()
                if written > outputSize { return }
            }
            let number = decode(ld)
            if number < 256 {
                window[unpPtr] = UInt8(number)
                unpPtr += 1
                continue
            }
            if number >= 271 {
                let slot = number - 271
                var length = Self.lengthBase[slot] + 3
                let bits = Self.lengthBits[slot]
                if bits > 0 {
                    length += getbits() >> (16 - bits)
                    addbits(bits)
                }
                let distanceSlot = decode(dd)
                guard distanceSlot < 60 else { throw ArchiveError.corrupted }
                var distance = Self.distanceBase30[distanceSlot] + 1
                let distanceBits = Self.distanceBits30[distanceSlot]
                if distanceBits > 0 {
                    if distanceSlot > 9 {
                        if distanceBits > 4 {
                            distance += (getbits() >> (20 - distanceBits)) << 4
                            addbits(distanceBits - 4)
                        }
                        if lowDistRepCount > 0 {
                            lowDistRepCount -= 1
                            distance += prevLowDist
                        } else {
                            let low = decode(ldd)
                            if low == 16 {
                                lowDistRepCount = 15 - 1
                                distance += prevLowDist
                            } else {
                                distance += low
                                prevLowDist = low
                            }
                        }
                    } else {
                        distance += getbits() >> (16 - distanceBits)
                        addbits(distanceBits)
                    }
                }
                if distance >= 0x2000 {
                    length += 1
                    if distance >= 0x40000 { length += 1 }
                }
                insertOldDist(distance)
                lastLength = length
                copyString(length: length, distance: distance)
                continue
            }
            if number == 256 {
                if try !readEndOfBlock30() { break }
                continue
            }
            if number == 257 {
                try readVMCode()
                continue
            }
            if number == 258 {
                if lastLength != 0 { copyString(length: lastLength, distance: oldDist[0]) }
                continue
            }
            if number < 263 {
                let index = number - 259
                let distance = oldDist[index]
                var i = index
                while i > 0 {
                    oldDist[i] = oldDist[i - 1]
                    i -= 1
                }
                oldDist[0] = distance
                let slot = decode(rd)
                guard slot < 28 else { throw ArchiveError.corrupted }
                var length = Self.lengthBase[slot] + 2
                let bits = Self.lengthBits[slot]
                if bits > 0 {
                    length += getbits() >> (16 - bits)
                    addbits(bits)
                }
                lastLength = length
                copyString(length: length, distance: distance)
                continue
            }
            if number < 272 {
                let slot = number - 263
                var distance = Self.shortBase[slot] + 1
                let bits = Self.shortBits[slot]
                if bits > 0 {
                    distance += getbits() >> (16 - bits)
                    addbits(bits)
                }
                insertOldDist(distance)
                lastLength = 2
                copyString(length: 2, distance: distance)
                continue
            }
        }
        try writeBuffer30()
    }

    // MARK: - RAR 2.9 filters

    enum StandardFilter { case none, e8, e8e9, itanium, delta, rgb, audio }

    struct Filter30 {
        var parent: Int
        var blockStart: Int
        var blockLength: Int
        var nextWindow: Bool
        var registers: [UInt32]
        var type: StandardFilter
    }

    /// Reads a number of a filter's code: 4, 8, 16 or 32 bits.
    private struct CodeReader {
        let bytes: [UInt8]
        var bitPosition = 0

        func bits16() -> Int {
            let byte = bitPosition >> 3
            func at(_ index: Int) -> Int { index < bytes.count ? Int(bytes[index]) : 0 }
            let value = at(byte) << 16 | at(byte + 1) << 8 | at(byte + 2)
            return (value >> (8 - bitPosition & 7)) & 0xFFFF
        }

        mutating func add(_ count: Int) { bitPosition += count }

        mutating func readData() -> UInt32 {
            let data = bits16()
            switch data & 0xC000 {
            case 0:
                add(6)
                return UInt32((data >> 10) & 0xF)
            case 0x4000:
                if data & 0x3C00 == 0 {
                    add(14)
                    return 0xFFFF_FF00 | UInt32((data >> 2) & 0xFF)
                }
                add(10)
                return UInt32((data >> 6) & 0xFF)
            case 0x8000:
                add(2)
                let value = bits16()
                add(16)
                return UInt32(value)
            default:
                add(2)
                let high = bits16()
                add(16)
                let low = bits16()
                add(16)
                return UInt32(high) << 16 | UInt32(low)
            }
        }

        var overflowed: Bool { bitPosition >> 3 >= bytes.count }
    }

    private func readVMCode() throws {
        let first = getbits() >> 8
        addbits(8)
        var length = (first & 7) + 1
        if length == 7 {
            length = getbits() >> 8 + 7
            addbits(8)
        } else if length == 8 {
            length = getbits()
            addbits(16)
        }
        guard length > 0 else { throw ArchiveError.corrupted }
        var code: [UInt8] = []
        code.reserveCapacity(length)
        for _ in 0..<length {
            if inputExhausted { throw ArchiveError.corrupted }
            code.append(UInt8(getbits() >> 8))
            addbits(8)
        }
        try addVMCode(first: first, code: code)
    }

    private func addVMCode(first: Int, code: [UInt8]) throws {
        var reader = CodeReader(bytes: code)
        var position: Int
        if first & 0x80 != 0 {
            position = Int(reader.readData())
            if position == 0 {
                filterTypes30 = []
                oldFilterLengths = []
                stack30 = []
            } else {
                position -= 1
            }
        } else {
            position = lastFilter
        }
        guard position <= filterTypes30.count, position <= oldFilterLengths.count, position < 8192 else {
            throw ArchiveError.corrupted
        }
        lastFilter = position
        let isNew = position == filterTypes30.count
        if isNew {
            filterTypes30.append(.none)
            oldFilterLengths.append(0)
        }
        var blockStart = Int(reader.readData())
        if first & 0x40 != 0 { blockStart += 258 }
        var filter = Filter30(parent: position, blockStart: (blockStart + unpPtr) & mask, blockLength: 0, nextWindow: false,
                              registers: [UInt32](repeating: 0, count: 7), type: .none)
        if first & 0x20 != 0 {
            filter.blockLength = Int(reader.readData())
            oldFilterLengths[position] = filter.blockLength
        } else {
            filter.blockLength = position < oldFilterLengths.count ? oldFilterLengths[position] : 0
        }
        filter.nextWindow = wrPtr != unpPtr && (wrPtr - unpPtr) & mask <= blockStart
        filter.registers[4] = UInt32(truncatingIfNeeded: filter.blockLength)
        if first & 0x10 != 0 {
            let initMask = reader.bits16() >> 9
            reader.add(7)
            for register in 0..<7 where initMask & (1 << register) != 0 {
                filter.registers[register] = reader.readData()
            }
        }
        if isNew {
            let size = Int(reader.readData())
            guard size > 0, size < 0x10000 else { throw ArchiveError.corrupted }
            var program: [UInt8] = []
            for _ in 0..<size {
                guard !reader.overflowed else { throw ArchiveError.corrupted }
                program.append(UInt8(reader.bits16() >> 8))
                reader.add(8)
            }
            filterTypes30[position] = Self.standardFilter(program)
        }
        filter.type = filterTypes30[position]
        // Filters already run leave the stack; the new one goes after those still waiting.
        stack30.removeAll { $0 == nil }
        guard stack30.count < 8192 else { throw ArchiveError.corrupted }
        stack30.append(filter)
    }

    /// RAR 3 filters are programs for a virtual machine; archivers only ever wrote six standard ones, known by
    /// their size and CRC.
    private static func standardFilter(_ program: [UInt8]) -> StandardFilter {
        var xor: UInt8 = 0
        for byte in program.dropFirst() { xor ^= byte }
        guard xor == program.first else { return .none }
        let crc = CRC32.checksum(Data(program))
        switch (program.count, crc) {
        case (53, 0xAD57_6887): return .e8
        case (57, 0x3CD7_E57E): return .e8e9
        case (120, 0x3769_893F): return .itanium
        case (29, 0x0E06_077D): return .delta
        case (149, 0x1C2C_5DC8): return .rgb
        case (216, 0xBC85_E701): return .audio
        default: return .none
        }
    }

    private func writeBuffer30() throws {
        var writtenBorder = wrPtr
        var writeSize = (unpPtr - writtenBorder) & mask
        var index = 0
        while index < stack30.count {
            guard var filter = stack30[index] else {
                index += 1
                continue
            }
            if filter.nextWindow {
                filter.nextWindow = false
                stack30[index] = filter
                index += 1
                continue
            }
            let blockStart = filter.blockStart
            let blockLength = filter.blockLength
            if (blockStart - writtenBorder) & mask < writeSize {
                if writtenBorder != blockStart {
                    writeArea(from: writtenBorder, to: blockStart)
                    writtenBorder = blockStart
                    writeSize = (unpPtr - writtenBorder) & mask
                }
                if blockLength <= writeSize {
                    let blockEnd = (blockStart + blockLength) & mask
                    let copy = min(blockLength, Self.vmMemorySize)
                    if blockStart < blockEnd || blockEnd == 0 {
                        vmMemory.update(from: window + blockStart, count: copy)
                    } else {
                        let first = min(windowSize - blockStart, copy)
                        vmMemory.update(from: window + blockStart, count: first)
                        if copy > first { (vmMemory + first).update(from: window, count: copy - first) }
                    }
                    var (data, size) = run(filter)
                    stack30[index] = nil
                    // Several filters on the same block, one after the other.
                    while index + 1 < stack30.count {
                        guard let next = stack30[index + 1], next.blockStart == blockStart, next.blockLength == size,
                              !next.nextWindow else { break }
                        if data != vmMemory { vmMemory.update(from: data, count: min(size, Self.vmMemorySize)) }
                        (data, size) = run(next)
                        index += 1
                        stack30[index] = nil
                    }
                    writeData(data, size)
                    writtenBorder = blockEnd
                    writeSize = (unpPtr - writtenBorder) & mask
                } else {
                    // The filter's block isn't all decoded yet: it waits for the next write.
                    for later in index..<stack30.count where stack30[later]?.nextWindow == true {
                        stack30[later]?.nextWindow = false
                    }
                    wrPtr = writtenBorder
                    return
                }
            }
            index += 1
        }
        writeArea(from: writtenBorder, to: unpPtr)
        wrPtr = unpPtr
    }

    /// Runs a standard filter on the block in `vmMemory`: where its output is, and how long.
    private func run(_ filter: Filter30) -> (UnsafeMutablePointer<UInt8>, Int) {
        let size = Int(filter.registers[4]) & (Self.vmMemorySize - 1)
        let memory = vmMemory
        let r = filter.registers
        let offset = UInt32(truncatingIfNeeded: written)
        switch filter.type {
        case .e8, .e8e9:
            let dataSize = Int(r[4])
            guard dataSize <= Self.vmMemorySize, dataSize >= 4 else { return (memory, size) }
            Self.e8(memory, size: dataSize, offset: offset, e9: filter.type == .e8e9, wrapsAt: nil)
            return (memory, size)
        case .itanium:
            let dataSize = Int(r[4])
            guard dataSize <= Self.vmMemorySize, dataSize >= 21 else { return (memory, size) }
            Self.itanium(memory, size: dataSize, offset: offset)
            return (memory, size)
        case .delta:
            let dataSize = Int(r[4]), channels = Int(r[0])
            guard dataSize <= Self.vmMemorySize / 2, channels > 0, channels <= 1024 else { return (memory, size) }
            var source = 0
            for channel in 0..<channels {
                var previous: UInt8 = 0
                var destination = dataSize + channel
                while destination < dataSize * 2 {
                    previous = previous &- memory[source]
                    memory[destination] = previous
                    source += 1
                    destination += channels
                }
            }
            return (memory + size, size)
        case .rgb:
            let dataSize = Int(r[4]), width = Int(r[0]) - 3, posR = Int(r[1])
            guard dataSize <= Self.vmMemorySize / 2, dataSize >= 3, width <= dataSize, width >= 0, posR <= 2 else {
                return (memory, size)
            }
            let destination = memory + dataSize
            var source = 0
            for channel in 0..<3 {
                var previous = 0
                var i = channel
                while i < dataSize {
                    var predicted: Int
                    if i >= width + 3 {
                        let upper = Int(destination[i - width]), upperLeft = Int(destination[i - width - 3])
                        predicted = previous + upper - upperLeft
                        let pa = abs(predicted - previous), pb = abs(predicted - upper), pc = abs(predicted - upperLeft)
                        if pa <= pb && pa <= pc {
                            predicted = previous
                        } else if pb <= pc {
                            predicted = upper
                        } else {
                            predicted = upperLeft
                        }
                    } else {
                        predicted = previous
                    }
                    previous = (predicted - Int(memory[source])) & 0xFF
                    destination[i] = UInt8(previous)
                    source += 1
                    i += 3
                }
            }
            var i = posR
            while i < dataSize - 2 {
                let green = destination[i + 1]
                destination[i] = destination[i] &+ green
                destination[i + 2] = destination[i + 2] &+ green
                i += 3
            }
            return (destination, size)
        case .audio:
            let dataSize = Int(r[4]), channels = Int(r[0])
            guard dataSize <= Self.vmMemorySize / 2, channels > 0, channels <= 128 else { return (memory, size) }
            let destination = memory + dataSize
            var source = 0
            for channel in 0..<channels {
                var previousByte = 0, previousDelta = 0
                var dif = [Int](repeating: 0, count: 7)
                var d1 = 0, d2 = 0, d3 = 0
                var k1 = 0, k2 = 0, k3 = 0
                var i = channel, count = 0
                while i < dataSize {
                    d3 = d2
                    d2 = previousDelta - d1
                    d1 = previousDelta
                    var predicted = 8 * previousByte + k1 * d1 + k2 * d2 + k3 * d3
                    predicted = (predicted >> 3) & 0xFF
                    let current = Int(memory[source])
                    source += 1
                    predicted = (predicted - current) & 0xFF
                    destination[i] = UInt8(predicted)
                    previousDelta = Int(Int8(truncatingIfNeeded: predicted - previousByte))
                    previousByte = predicted
                    let d = Int(Int8(truncatingIfNeeded: current)) << 3
                    dif[0] += abs(d)
                    dif[1] += abs(d - d1)
                    dif[2] += abs(d + d1)
                    dif[3] += abs(d - d2)
                    dif[4] += abs(d + d2)
                    dif[5] += abs(d - d3)
                    dif[6] += abs(d + d3)
                    if count & 0x1F == 0 {
                        var minimum = dif[0], best = 0
                        dif[0] = 0
                        for j in 1..<7 {
                            if dif[j] < minimum {
                                minimum = dif[j]
                                best = j
                            }
                            dif[j] = 0
                        }
                        switch best {
                        case 1: if k1 >= -16 { k1 -= 1 }
                        case 2: if k1 < 16 { k1 += 1 }
                        case 3: if k2 >= -16 { k2 -= 1 }
                        case 4: if k2 < 16 { k2 += 1 }
                        case 5: if k3 >= -16 { k3 -= 1 }
                        case 6: if k3 < 16 { k3 += 1 }
                        default: break
                        }
                    }
                    i += channels
                    count += 1
                }
            }
            return (destination, size)
        case .none:
            return (memory, size)
        }
    }

    /// x86 calls and jumps back from absolute to relative addresses.
    private static func e8(_ data: UnsafeMutablePointer<UInt8>, size: Int, offset: UInt32, e9: Bool, wrapsAt: UInt32?) {
        let fileSize: UInt32 = 0x100_0000
        var position = 0
        while position + 4 < size {
            let byte = data[position]
            position += 1
            if byte == 0xE8 || (e9 && byte == 0xE9) {
                var at = UInt32(truncatingIfNeeded: position) &+ offset
                if let wrapsAt { at %= wrapsAt }
                let address = UInt32(data[position]) | UInt32(data[position + 1]) << 8 | UInt32(data[position + 2]) << 16
                    | UInt32(data[position + 3]) << 24
                var value: UInt32?
                if address & 0x8000_0000 != 0 {
                    if (address &+ at) & 0x8000_0000 == 0 { value = address &+ fileSize }
                } else if (address &- fileSize) & 0x8000_0000 != 0 {
                    value = address &- at
                }
                if let value {
                    data[position] = UInt8(truncatingIfNeeded: value)
                    data[position + 1] = UInt8(truncatingIfNeeded: value >> 8)
                    data[position + 2] = UInt8(truncatingIfNeeded: value >> 16)
                    data[position + 3] = UInt8(truncatingIfNeeded: value >> 24)
                }
                position += 4
            }
        }
    }

    private static func itanium(_ data: UnsafeMutablePointer<UInt8>, size: Int, offset: UInt32) {
        func getBits(_ base: UnsafeMutablePointer<UInt8>, _ bitPosition: Int, _ count: Int) -> UInt32 {
            let address = bitPosition / 8, bit = UInt32(bitPosition & 7)
            var field = UInt32(base[address]) | UInt32(base[address + 1]) << 8 | UInt32(base[address + 2]) << 16
                | UInt32(base[address + 3]) << 24
            field >>= bit
            return field & (0xFFFF_FFFF >> UInt32(32 - count))
        }
        func setBits(_ base: UnsafeMutablePointer<UInt8>, _ value: UInt32, _ bitPosition: Int, _ count: Int) {
            let address = bitPosition / 8, bit = UInt32(bitPosition & 7)
            var andMask = ~((0xFFFF_FFFF >> UInt32(32 - count)) << bit)
            var field = value << bit
            for i in 0..<4 {
                base[address + i] &= UInt8(truncatingIfNeeded: andMask)
                base[address + i] |= UInt8(truncatingIfNeeded: field)
                andMask = andMask >> 8 | 0xFF00_0000
                field >>= 8
            }
        }
        let masks: [UInt8] = [4, 4, 6, 6, 0, 0, 7, 7, 4, 4, 0, 0, 4, 4, 0, 0]
        var fileOffset = offset >> 4
        var position = 0
        while position < size - 21 {
            let block = data + position
            let byte = Int(block[0] & 0x1F) - 0x10
            if byte >= 0 {
                let commandMask = masks[byte]
                if commandMask != 0 {
                    for i in 0...2 where commandMask & (1 << i) != 0 {
                        let start = i * 41 + 5
                        if getBits(block, start + 37, 4) == 5 {
                            let address = getBits(block, start + 13, 20)
                            setBits(block, (address &- fileOffset) & 0xFFFFF, start + 13, 20)
                        }
                    }
                }
            }
            position += 16
            fileOffset &+= 1
        }
    }

    // MARK: - RAR 5

    struct Filter50 {
        enum Kind: Int { case delta = 0, e8 = 1, e8e9 = 2, arm = 3, none = 99 }
        var kind: Kind
        var blockStart: Int
        var blockLength: Int
        var channels: Int
        var nextWindow: Bool
    }

    private func readBlockHeader50() throws -> Bool {
        addbits((8 - inBit) & 7)
        let flags = getbits() >> 8
        addbits(8)
        let byteCount = (flags >> 3) & 3 + 1
        guard byteCount < 4 else { return false }
        blockBitSize = flags & 7 + 1
        let checksum = getbits() >> 8
        addbits(8)
        var size = 0
        for i in 0..<byteCount {
            size += (getbits() >> 8) << (i * 8)
            addbits(8)
        }
        guard checksum == (0x5A ^ flags ^ size ^ (size >> 8) ^ (size >> 16)) & 0xFF else { throw ArchiveError.corrupted }
        blockSize = size
        blockStart = inAddr
        lastBlockInFile = flags & 0x40 != 0
        tablePresent = flags & 0x80 != 0
        return true
    }

    private func readTables50() throws {
        guard tablePresent else { return }
        bd.build(readBitLengths(), size: 20)
        let table = try readTableLengths(count: 430, previous: nil)
        tablesRead = true
        ld.build(Array(table[0..<306]), size: 306)
        dd.build(Array(table[306..<370]), size: 64)
        ldd.build(Array(table[370..<386]), size: 16)
        rd.build(Array(table[386..<430]), size: 44)
    }

    private func slotToLength(_ slot: Int) -> Int {
        var bits = 0, length = 2
        if slot < 8 {
            length += slot
        } else {
            bits = slot / 4 - 1
            length += (4 | slot & 3) << bits
        }
        if bits > 0 {
            length += getbits() >> (16 - bits)
            addbits(bits)
        }
        return length
    }

    private func unpack50(solid: Bool) throws {
        guard try readBlockHeader50() else { throw ArchiveError.corrupted }
        try readTables50()
        guard tablesRead else { throw ArchiveError.corrupted }
        while true {
            unpPtr &= mask
            // At the end of a block: the next one, unless the file ends.
            var fileDone = false
            while inAddr > blockStart + blockSize - 1 || (inAddr == blockStart + blockSize - 1 && inBit >= blockBitSize) {
                if lastBlockInFile {
                    fileDone = true
                    break
                }
                guard try readBlockHeader50() else { throw ArchiveError.corrupted }
                try readTables50()
            }
            if fileDone || inputExhausted { break }
            if (writeBorder - unpPtr) & mask < 0x1001 + 3, writeBorder != unpPtr {
                writeBuffer50()
                if written > outputSize { return }
            }
            let slot = decode(ld)
            if slot < 256 {
                window[unpPtr] = UInt8(slot)
                unpPtr += 1
                continue
            }
            if slot >= 262 {
                var length = slotToLength(slot - 262)
                var distance = 1
                let distanceSlot = decode(dd)
                var bits = 0
                if distanceSlot < 4 {
                    distance += distanceSlot
                } else {
                    bits = distanceSlot / 2 - 1
                    distance += (2 | distanceSlot & 1) << bits
                }
                if bits > 0 {
                    if bits >= 4 {
                        if bits > 4 {
                            distance += (getbits32() >> (36 - bits)) << 4
                            addbits(bits - 4)
                        }
                        distance += decode(ldd)
                    } else {
                        distance += getbits32() >> (32 - bits)
                        addbits(bits)
                    }
                }
                if distance > 0x100 {
                    length += 1
                    if distance > 0x2000 {
                        length += 1
                        if distance > 0x40000 { length += 1 }
                    }
                }
                insertOldDist(distance)
                lastLength = length
                copyString(length: length, distance: distance)
                continue
            }
            if slot == 256 {
                try readFilter50()
                continue
            }
            if slot == 257 {
                if lastLength != 0 { copyString(length: lastLength, distance: oldDist[0]) }
                continue
            }
            // 258...261: an old distance.
            let index = slot - 258
            let distance = oldDist[index]
            var i = index
            while i > 0 {
                oldDist[i] = oldDist[i - 1]
                i -= 1
            }
            oldDist[0] = distance
            let length = slotToLength(decode(rd))
            lastLength = length
            copyString(length: length, distance: distance)
        }
        writeBuffer50()
    }

    private func readFilterData() -> Int {
        let count = getbits() >> 14 + 1
        addbits(2)
        var value = 0
        for i in 0..<count {
            value += (getbits() >> 8) << (i * 8)
            addbits(8)
        }
        return value
    }

    private func readFilter50() throws {
        let start = readFilterData()
        var length = readFilterData()
        if length > 0x400000 { length = 0 }
        let type = getbits() >> 13
        addbits(3)
        var channels = 0
        if type == 0 {
            channels = getbits() >> 11 + 1
            addbits(5)
        }
        if filters50.count >= 8192 {
            writeBuffer50()
            if filters50.count >= 8192 { filters50 = [] }
        }
        let nextWindow = wrPtr != unpPtr && (wrPtr - unpPtr) & mask <= start
        filters50.append(Filter50(kind: Filter50.Kind(rawValue: type) ?? .none, blockStart: (start + unpPtr) & mask,
                                  blockLength: length, channels: channels, nextWindow: nextWindow))
    }

    private func writeBuffer50() {
        var writtenBorder = wrPtr
        let fullWriteSize = (unpPtr - writtenBorder) & mask
        var writeSizeLeft = fullWriteSize
        var notAllProcessed = false
        var index = 0
        while index < filters50.count {
            var filter = filters50[index]
            if filter.kind == .none {
                index += 1
                continue
            }
            if filter.nextWindow {
                if (filter.blockStart - wrPtr) & mask <= fullWriteSize {
                    filter.nextWindow = false
                    filters50[index] = filter
                }
                index += 1
                continue
            }
            let blockStart = filter.blockStart, blockLength = filter.blockLength
            if (blockStart - writtenBorder) & mask < writeSizeLeft {
                if writtenBorder != blockStart {
                    writeArea(from: writtenBorder, to: blockStart)
                    writtenBorder = blockStart
                    writeSizeLeft = (unpPtr - writtenBorder) & mask
                }
                if blockLength <= writeSizeLeft {
                    if blockLength > 0 {
                        let blockEnd = (blockStart + blockLength) & mask
                        let memory = UnsafeMutablePointer<UInt8>.allocate(capacity: blockLength + 8)
                        defer { memory.deallocate() }
                        if blockStart < blockEnd || blockEnd == 0 {
                            memory.update(from: window + blockStart, count: blockLength)
                        } else {
                            let first = windowSize - blockStart
                            memory.update(from: window + blockStart, count: first)
                            (memory + first).update(from: window, count: blockEnd)
                        }
                        let result = apply(filter, memory, blockLength)
                        filters50[index].kind = .none
                        writeData(result, blockLength)
                        if result != memory { result.deallocate() }
                        writtenBorder = blockEnd
                        writeSizeLeft = (unpPtr - writtenBorder) & mask
                    } else {
                        filters50[index].kind = .none
                    }
                } else {
                    wrPtr = writtenBorder
                    for later in index..<filters50.count where filters50[later].kind != .none {
                        filters50[later].nextWindow = false
                    }
                    notAllProcessed = true
                    break
                }
            }
            index += 1
        }
        filters50.removeAll { $0.kind == .none }
        if !notAllProcessed {
            writeArea(from: writtenBorder, to: unpPtr)
            wrPtr = unpPtr
        }
        writeBorder = (unpPtr + min(windowSize, 0x400000)) & mask
        if writeBorder == unpPtr || (wrPtr != unpPtr && (wrPtr - unpPtr) & mask < (writeBorder - unpPtr) & mask) {
            writeBorder = wrPtr
        }
    }

    private func apply(_ filter: Filter50, _ data: UnsafeMutablePointer<UInt8>, _ size: Int) -> UnsafeMutablePointer<UInt8> {
        let offset = UInt32(truncatingIfNeeded: written)
        switch filter.kind {
        case .e8, .e8e9:
            Self.e8(data, size: size, offset: offset, e9: filter.kind == .e8e9, wrapsAt: 0x100_0000)
            return data
        case .arm:
            var position = 0
            while position + 3 < size {
                let d = data + position
                if d[3] == 0xEB {
                    var value = UInt32(d[0]) | UInt32(d[1]) << 8 | UInt32(d[2]) << 16
                    value &-= (offset &+ UInt32(position)) / 4
                    d[0] = UInt8(truncatingIfNeeded: value)
                    d[1] = UInt8(truncatingIfNeeded: value >> 8)
                    d[2] = UInt8(truncatingIfNeeded: value >> 16)
                }
                position += 4
            }
            return data
        case .delta:
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: size + 8)
            var source = 0
            for channel in 0..<filter.channels {
                var previous: UInt8 = 0
                var position = channel
                while position < size {
                    previous = previous &- data[source]
                    destination[position] = previous
                    source += 1
                    position += filter.channels
                }
            }
            return destination
        case .none:
            return data
        }
    }
}

/// A canonical Huffman code, decoded the way RAR does: by bit length first, with a lookup table for short codes.
nonisolated final class HuffmanTable {
    private(set) var maxNumber = 0
    private(set) var quickBits = 7
    let decodeLen = UnsafeMutablePointer<Int>.allocate(capacity: 16)
    let decodePos = UnsafeMutablePointer<Int>.allocate(capacity: 16)
    let decodeNum = UnsafeMutablePointer<UInt16>.allocate(capacity: 512)
    let quickLen = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 10)
    let quickNum = UnsafeMutablePointer<UInt16>.allocate(capacity: 1 << 10)

    init() {
        decodeLen.initialize(repeating: 0, count: 16)
        decodePos.initialize(repeating: 0, count: 16)
        decodeNum.initialize(repeating: 0, count: 512)
        quickLen.initialize(repeating: 0, count: 1 << 10)
        quickNum.initialize(repeating: 0, count: 1 << 10)
    }

    deinit {
        decodeLen.deallocate()
        decodePos.deallocate()
        decodeNum.deallocate()
        quickLen.deallocate()
        quickNum.deallocate()
    }

    func build(_ lengths: [UInt8], size: Int) {
        maxNumber = size
        var counts = [Int](repeating: 0, count: 16)
        for index in 0..<size { counts[Int(lengths[index] & 0xF)] += 1 }
        counts[0] = 0
        decodeNum.update(repeating: 0, count: 512)
        decodePos[0] = 0
        decodeLen[0] = 0
        var upper = 0
        for length in 1..<16 {
            upper += counts[length]
            decodeLen[length] = upper << (16 - length)
            upper *= 2
            decodePos[length] = decodePos[length - 1] + counts[length - 1]
        }
        var positions = (0..<16).map { decodePos[$0] }
        for index in 0..<size {
            let length = Int(lengths[index] & 0xF)
            if length != 0 {
                decodeNum[positions[length]] = UInt16(index)
                positions[length] += 1
            }
        }
        quickBits = size == 306 || size == 299 ? 10 : 7
        var length = 0
        for code in 0..<(1 << quickBits) {
            let field = code << (16 - quickBits)
            while length < 16 && field >= decodeLen[length] { length += 1 }
            quickLen[code] = UInt8(length)
            let distance = (field - decodeLen[length - 1]) >> (16 - length)
            let position = length < 16 ? decodePos[length] + distance : size
            quickNum[code] = position < size ? decodeNum[position] : 0
        }
    }
}
