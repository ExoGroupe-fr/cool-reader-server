import Foundation

/// A QR code (ISO/IEC 18004) holding a text in byte mode, as UTF-8: the smallest version that fits at the chosen
/// level, with the mask that scores the lowest penalty. The admin shows invitations with it, for an iPhone to scan.
nonisolated struct QRCode: Sendable {
    /// How much of the code can be damaged and still read: about 7, 15, 25 and 30 %.
    enum Correction: Sendable {
        case low, medium, quartile, high

        /// Its row in the tables below.
        fileprivate var index: Int {
            switch self {
            case .low: 0
            case .medium: 1
            case .quartile: 2
            case .high: 3
            }
        }

        /// The two bits the format information gives it.
        fileprivate var bits: Int { [0b01, 0b00, 0b11, 0b10][index] }
    }

    /// The text needs more than version 40 holds: 2 953 bytes at the low level, 1 273 at the high one.
    struct TooLong: Error {}

    /// From 1 (21 × 21 modules) to 40 (177 × 177).
    let version: Int
    /// Modules per side, without the quiet zone.
    let size: Int
    private let modules: [Bool]

    init(_ text: String, correction: Correction = .medium) throws {
        let bytes = Array(text.utf8)
        // The mode, the length, then the bytes.
        guard let version = (1...40).first(where: { (version: Int) -> Bool in
            4 + (version < 10 ? 8 : 16) + 8 * bytes.count <= 8 * Self.dataCodewords(version, correction)
        }) else { throw TooLong() }
        var matrix = Matrix(version: version)
        matrix.place(Self.codewords(bytes, version: version, correction: correction))
        var best = matrix
        var lowest = Int.max
        for mask in 0..<8 {
            var candidate = matrix
            candidate.apply(mask: mask)
            candidate.drawFormat(Self.formatBits(correction, mask: mask))
            let penalty = candidate.penalty()
            if penalty < lowest { (best, lowest) = (candidate, penalty) }
        }
        self.version = version
        size = matrix.size
        modules = best.dark
    }

    /// True for a dark module; (0, 0) is the top left one.
    subscript(x: Int, y: Int) -> Bool { modules[y * size + x] }

    /// The code and its quiet zone, `moduleSize` pixels a module: black runs on a white square whatever the page's
    /// colours, and nothing a `default-src 'self'` policy blocks (no script, style or link).
    func svg(moduleSize: Int = 8, title: String? = nil) -> String {
        let quiet = 4, side = size + 2 * quiet
        var path = ""
        for y in 0..<size {
            var x = 0
            while x < size {
                guard self[x, y] else {
                    x += 1
                    continue
                }
                let start = x
                while x < size, self[x, y] { x += 1 }
                path += "M\(start + quiet),\(y + quiet)h\(x - start)v1h-\(x - start)z"
            }
        }
        let label = title.map { (title: String) -> String in
            let escaped = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            return "<title>\(escaped)</title>"
        } ?? ""
        return """
            <svg xmlns="http://www.w3.org/2000/svg" role="img" width="\(side * moduleSize)" height="\(side * moduleSize)" \
            viewBox="0 0 \(side) \(side)" shape-rendering="crispEdges">\(label)<rect width="\(side)" height="\(side)" \
            fill="#fff"/><path fill="#000" d="\(path)"/></svg>
            """
    }

    /// The codewords a version holds at a level, less those of the error correction.
    static func dataCodewords(_ version: Int, _ correction: Correction) -> Int {
        let row = correction.index
        return codewordCounts[version - 1] - blockCounts[row][version - 1] * correctionCounts[row][version - 1]
    }

    /// The mode, length and bytes, a terminator and padding, cut into blocks that each get their error correction;
    /// then the blocks interleaved, codeword by codeword.
    static func codewords(_ bytes: [UInt8], version: Int, correction: Correction) -> [UInt8] {
        let capacity = dataCodewords(version, correction)
        var bits: [Bool] = []
        func append(_ value: Int, _ count: Int) {
            for shift in stride(from: count - 1, through: 0, by: -1) { bits.append((value >> shift) & 1 == 1) }
        }
        append(0b0100, 4)
        append(bytes.count, version < 10 ? 8 : 16)
        for byte in bytes { append(Int(byte), 8) }
        append(0, min(4, 8 * capacity - bits.count))
        append(0, (8 - bits.count % 8) % 8)
        var data = stride(from: 0, to: bits.count, by: 8).map { (start: Int) -> UInt8 in
            bits[start..<start + 8].reduce(0) { (byte: UInt8, bit: Bool) -> UInt8 in byte << 1 | (bit ? 1 : 0) }
        }
        for index in 0..<capacity - data.count { data.append(index % 2 == 0 ? 0xEC : 0x11) }

        // When the blocks can't be equal, the last ones hold one more data codeword.
        let blockCount = blockCounts[correction.index][version - 1]
        let correctionCount = correctionCounts[correction.index][version - 1]
        let shortLength = capacity / blockCount, shortBlocks = blockCount - capacity % blockCount
        var blocks: [[UInt8]] = []
        var start = 0
        for index in 0..<blockCount {
            let length = index < shortBlocks ? shortLength : shortLength + 1
            blocks.append(Array(data[start..<start + length]))
            start += length
        }
        let corrections = blocks.map { (block: [UInt8]) -> [UInt8] in reedSolomon(block, count: correctionCount) }
        var result: [UInt8] = []
        for index in 0...shortLength {
            for block in blocks where index < block.count { result.append(block[index]) }
        }
        for index in 0..<correctionCount {
            for block in corrections { result.append(block[index]) }
        }
        return result
    }

    /// A block's error correction codewords: the remainder of its polynomial times x^count, divided by the generator
    /// (x − 1)(x − α)…(x − α^(count − 1)) in GF(256), α = 2.
    static func reedSolomon(_ data: [UInt8], count: Int) -> [UInt8] {
        // The generator's coefficients, highest power first, without its leading 1.
        var generator = [UInt8](repeating: 0, count: count)
        generator[count - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<count {
            for index in 0..<count {
                generator[index] = multiply(generator[index], root)
                if index + 1 < count { generator[index] ^= generator[index + 1] }
            }
            root = multiply(root, 2)
        }
        var remainder = [UInt8](repeating: 0, count: count)
        for byte in data {
            let factor = byte ^ remainder.removeFirst()
            remainder.append(0)
            for index in 0..<count { remainder[index] ^= multiply(generator[index], factor) }
        }
        return remainder
    }

    /// A product in GF(256) modulo x⁸ + x⁴ + x³ + x² + 1, by shifts and additions.
    static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var product = 0
        for bit in stride(from: 7, through: 0, by: -1) {
            product = (product << 1) ^ ((product >> 7) * 0x11D)
            if (y >> bit) & 1 == 1 { product ^= Int(x) }
        }
        return UInt8(product)
    }

    /// The level and mask, their BCH(15, 5) code, then XOR 101010000010010 so that no format is all light.
    static func formatBits(_ correction: Correction, mask: Int) -> Int {
        let data = correction.bits << 3 | mask
        var remainder = data
        for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
        return (data << 10 | remainder) ^ 0x5412
    }

    /// The version and its BCH(18, 6) code, which versions 7 and up carry.
    static func versionBits(_ version: Int) -> Int {
        var remainder = version
        for _ in 0..<12 { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
        return version << 12 | remainder
    }

    /// Whether a mask flips the module in column x, row y.
    static func flips(_ mask: Int, _ x: Int, _ y: Int) -> Bool {
        switch mask {
        case 0: (x + y) % 2 == 0
        case 1: y % 2 == 0
        case 2: x % 3 == 0
        case 3: (x + y) % 3 == 0
        case 4: (x / 3 + y / 2) % 2 == 0
        case 5: x * y % 2 + x * y % 3 == 0
        case 6: (x * y % 2 + x * y % 3) % 2 == 0
        default: ((x + y) % 2 + x * y % 3) % 2 == 0
        }
    }

    /// Penalties 1 and 3 on a row or column: 3 for a run of five modules of one colour and 1 per module beyond, and
    /// 40 for each dark-light-dark-dark-dark-light-dark pattern with four light modules before or after it, the quiet
    /// zone included.
    static func linePenalty(_ line: [Bool]) -> Int {
        var score = 0
        var run = 0
        for (index, module) in line.enumerated() {
            run = index > 0 && module == line[index - 1] ? run + 1 : 1
            if run == 5 { score += 3 } else if run > 5 { score += 1 }
        }
        let finder = [true, false, true, true, true, false, true]
        func isLight(_ range: Range<Int>) -> Bool { range.allSatisfy { $0 < 0 || $0 >= line.count || !line[$0] } }
        for start in 0...line.count - 7 where line[start..<start + 7].elementsEqual(finder) {
            if isLight(start - 4..<start) || isLight(start + 7..<start + 11) { score += 40 }
        }
        return score
    }

    /// Codewords per version, data and error correction together.
    private static let codewordCounts: [Int] = [
        26, 44, 70, 100, 134, 172, 196, 242, 292, 346, 404, 466, 532, 581, 655, 733, 815, 901, 991, 1085, 1156, 1258, 1364, 1474,
        1588, 1706, 1828, 1921, 2051, 2185, 2323, 2465, 2611, 2761, 2876, 3034, 3196, 3362, 3532, 3706,
    ]
    /// Error correction codewords per block, by level (L, M, Q, H) then version.
    private static let correctionCounts: [[Int]] = [
        [7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
        [13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    ]
    /// Blocks the codewords are cut into, by level then version.
    private static let blockCounts: [[Int]] = [
        [1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
        [1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
        [1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
        [1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
    ]
    /// Rows and columns of the alignment patterns' centres, by version.
    private static let alignmentCentres: [[Int]] = [
        [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50], [6, 30, 54], [6, 32, 58],
        [6, 34, 62], [6, 26, 46, 66], [6, 26, 48, 70], [6, 26, 50, 74], [6, 30, 54, 78], [6, 30, 56, 82], [6, 30, 58, 86],
        [6, 34, 62, 90], [6, 28, 50, 72, 94], [6, 26, 50, 74, 98], [6, 30, 54, 78, 102], [6, 28, 54, 80, 106], [6, 32, 58, 84, 110],
        [6, 30, 58, 86, 114], [6, 34, 62, 90, 118], [6, 26, 50, 74, 98, 122], [6, 30, 54, 78, 102, 126], [6, 26, 52, 78, 104, 130],
        [6, 30, 56, 82, 108, 134], [6, 34, 60, 86, 112, 138], [6, 30, 58, 86, 114, 142], [6, 34, 62, 90, 118, 146],
        [6, 30, 54, 78, 102, 126, 150], [6, 24, 50, 76, 102, 128, 154], [6, 28, 54, 80, 106, 132, 158], [6, 32, 58, 84, 110, 136, 162],
        [6, 26, 54, 82, 110, 138, 166], [6, 30, 58, 86, 114, 142, 170],
    ]

    /// The modules being laid out, and those the patterns reserve: data and masks go around them.
    private struct Matrix {
        let size: Int
        var dark: [Bool]
        var reserved: [Bool]

        /// The timing, finder and alignment patterns, the version information, and room for the format.
        init(version: Int) {
            size = version * 4 + 17
            dark = [Bool](repeating: false, count: size * size)
            reserved = dark
            for index in 0..<size {
                set(6, index, index % 2 == 0)
                set(index, 6, index % 2 == 0)
            }
            // The finders: concentric squares in three corners, and the light border that separates them from the data.
            for (x, y) in [(3, 3), (size - 4, 3), (3, size - 4)] {
                for dy in -4...4 {
                    for dx in -4...4 where (0..<size).contains(x + dx) && (0..<size).contains(y + dy) {
                        let ring = max(abs(dx), abs(dy))
                        set(x + dx, y + dy, ring != 2 && ring != 4)
                    }
                }
            }
            let centres = QRCode.alignmentCentres[version - 1]
            let last = centres.count - 1
            for (row, y) in centres.enumerated() {
                for (column, x) in centres.enumerated() {
                    // Not over the finders.
                    if (row == 0 && (column == 0 || column == last)) || (row == last && column == 0) { continue }
                    for dy in -2...2 {
                        for dx in -2...2 { set(x + dx, y + dy, max(abs(dx), abs(dy)) != 1) }
                    }
                }
            }
            drawFormat(0)
            if version >= 7 {
                let bits = QRCode.versionBits(version)
                for index in 0..<18 {
                    let isDark = (bits >> index) & 1 == 1
                    set(size - 11 + index % 3, index / 3, isDark)
                    set(index / 3, size - 11 + index % 3, isDark)
                }
            }
        }

        /// The 15 format bits, twice: around the top left finder, and split between the two others. And the dark
        /// module beside the bottom left finder.
        mutating func drawFormat(_ bits: Int) {
            func bit(_ index: Int) -> Bool { (bits >> index) & 1 == 1 }
            for index in 0..<6 { set(8, index, bit(index)) }
            set(8, 7, bit(6))
            set(8, 8, bit(7))
            set(7, 8, bit(8))
            for index in 9..<15 { set(14 - index, 8, bit(index)) }
            for index in 0..<8 { set(size - 1 - index, 8, bit(index)) }
            for index in 8..<15 { set(8, size - 15 + index, bit(index)) }
            set(8, size - 8, true)
        }

        /// The codewords' bits, most significant first, up then down two-module columns from the bottom right corner,
        /// skipping the reserved modules and the vertical timing pattern. Modules left over stay light.
        mutating func place(_ codewords: [UInt8]) {
            var index = 0
            var right = size - 1
            var upward = true
            while right > 0 {
                if right == 6 { right = 5 }
                for step in 0..<size {
                    let y = upward ? size - 1 - step : step
                    for x in [right, right - 1] where !reserved[y * size + x] && index < codewords.count * 8 {
                        dark[y * size + x] = (codewords[index / 8] >> (7 - index % 8)) & 1 == 1
                        index += 1
                    }
                }
                upward.toggle()
                right -= 2
            }
        }

        /// Flips the data modules the mask picks; applied twice, it undoes itself.
        mutating func apply(mask: Int) {
            for y in 0..<size {
                for x in 0..<size where !reserved[y * size + x] && QRCode.flips(mask, x, y) { dark[y * size + x].toggle() }
            }
        }

        /// The four penalties of the standard: runs and finder-like patterns in rows and columns, 2 × 2 blocks of one
        /// colour, and 10 for each 5 % that dark modules stray from half.
        func penalty() -> Int {
            var score = 0
            for index in 0..<size {
                score += QRCode.linePenalty((0..<size).map { (x: Int) -> Bool in dark[index * size + x] })
                score += QRCode.linePenalty((0..<size).map { (y: Int) -> Bool in dark[y * size + index] })
            }
            for y in 0..<size - 1 {
                for x in 0..<size - 1 {
                    let colour = dark[y * size + x]
                    if dark[y * size + x + 1] == colour, dark[(y + 1) * size + x] == colour, dark[(y + 1) * size + x + 1] == colour {
                        score += 3
                    }
                }
            }
            let darkCount = dark.filter { $0 }.count
            return score + 10 * (abs(20 * darkCount - 10 * dark.count) / dark.count)
        }

        /// A module of a pattern.
        private mutating func set(_ x: Int, _ y: Int, _ isDark: Bool) {
            dark[y * size + x] = isDark
            reserved[y * size + x] = true
        }
    }
}
