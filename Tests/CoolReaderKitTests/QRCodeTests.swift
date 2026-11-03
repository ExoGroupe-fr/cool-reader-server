import Foundation
import Testing
@testable import CoolReaderKit
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(CoreImage)
import CoreGraphics
import CoreImage
#endif

/// QR codes checked against the standard's numbers, then read back by Core Image's detector where there is one.
struct QRCodeTests {
    /// Format information for level M and every mask, and for the other levels (ISO/IEC 18004, annex C).
    @Test func encodesFormatInformation() {
        #expect((0..<8).map { (mask: Int) -> Int in QRCode.formatBits(.medium, mask: mask) } == [
            0b101010000010010, 0b101000100100101, 0b101111001111100, 0b101101101001011,
            0b100010111111001, 0b100000011001110, 0b100111110010111, 0b100101010100000,
        ])
        #expect(QRCode.formatBits(.low, mask: 0) == 0b111011111000100)
        #expect(QRCode.formatBits(.quartile, mask: 5) == 0b010000110000011)
        #expect(QRCode.formatBits(.high, mask: 7) == 0b000100000111011)
    }

    /// Version information (annex D): the version in 6 bits, then 12 bits of BCH code.
    @Test func encodesVersionInformation() {
        #expect(QRCode.versionBits(7) == 0b000111_110010010100)
        #expect(QRCode.versionBits(40) == 0b101000_110001101001)
    }

    /// The standard's example (annex I): "01234567" in a version 1-M code, 16 data codewords and 10 of correction.
    @Test func computesReedSolomonCodewords() {
        let data: [UInt8] = [0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11]
        #expect(QRCode.reedSolomon(data, count: 10) == [0xA5, 0x24, 0xD4, 0xC1, 0xED, 0x36, 0xC7, 0x87, 0x2C, 0x55])
    }

    /// The byte capacities of versions 1, 9, 10 and 40 (table 7): the most each holds, then one byte more.
    @Test func picksTheSmallestVersion() throws {
        let capacities: [(QRCode.Correction, [Int])] = [
            (.low, [17, 230, 271, 2953]), (.medium, [14, 180, 213, 2331]), (.quartile, [11, 130, 151, 1663]), (.high, [7, 98, 119, 1273]),
        ]
        for (correction, bytes) in capacities {
            for (version, count) in zip([1, 9, 10], bytes) {
                #expect(try QRCode(String(repeating: "a", count: count), correction: correction).version == version)
                #expect(try QRCode(String(repeating: "a", count: count + 1), correction: correction).version == version + 1)
            }
            let largest = try QRCode(String(repeating: "a", count: bytes[3]), correction: correction)
            #expect(largest.version == 40 && largest.size == 177)
            #expect(throws: QRCode.TooLong.self) { try QRCode(String(repeating: "a", count: bytes[3] + 1), correction: correction) }
        }
        // M by default, and UTF-8 bytes rather than characters.
        #expect(try QRCode(String(repeating: "é", count: 7)).version == 1)
        #expect(try QRCode(String(repeating: "é", count: 8)).version == 2)
    }

    /// The SVG paints the dark modules and only them, 4 modules in, over a white square that includes the quiet zone.
    @Test func drawsSVG() throws {
        let code = try QRCode(Self.invitation)
        let svg = code.svg(moduleSize: 6, title: #"Léa's <invitation> & "more""#)
        let side = code.size + 8
        #expect(svg.hasPrefix("<svg ") && svg.hasSuffix("</svg>"))
        #expect(svg.contains(#"width="\#(side * 6)" height="\#(side * 6)" viewBox="0 0 \#(side) \#(side)""#))
        #expect(svg.contains(#"role="img""#) && svg.contains(#"shape-rendering="crispEdges""#))
        #expect(svg.contains("<title>Léa's &lt;invitation&gt; &amp; &quot;more&quot;</title>"))
        #expect(svg.contains(##"<rect width="\##(side)" height="\##(side)" fill="#fff"/><path fill="#000" d=""##))
        for blocked in ["<script", "href", "style", "url(", "<image", "<foreignObject"] { #expect(!svg.contains(blocked)) }
        #expect(!code.svg().contains("<title>"))
        #expect(XMLParser(data: Data(svg.utf8)).parse())

        let start = try #require(svg.range(of: #" d=""#)).upperBound
        let path = svg[start...].prefix { (character: Character) -> Bool in character != "\"" }
        var painted = [Bool](repeating: false, count: side * side)
        for run in path.split(separator: "z") {
            // "M12,4h3v1h-3": a run of 3 modules from column 12 of row 4.
            let numbers = run.split(whereSeparator: { (character: Character) -> Bool in !character.isNumber && character != "-" })
                .compactMap { Int($0) }
            try #require(numbers.count == 5 && numbers[3] == 1 && numbers[4] == -numbers[2])
            for x in numbers[0]..<numbers[0] + numbers[2] { painted[numbers[1] * side + x] = true }
        }
        let expected = (0..<side * side).map { (index: Int) -> Bool in
            let x = index % side - 4, y = index / side - 4
            return (0..<code.size).contains(x) && (0..<code.size).contains(y) && code[x, y]
        }
        #expect(painted == expected)
    }

    /// An invitation link of the size the admin will show: server, name, addresses, certificate fingerprint, token.
    nonisolated static let invitation = "coolreader://connect?s=6f1c2a9e4b7d40c8a3e5f9b2d1c07e63&n=Cool%20Reader%20Server"
        + "&a=192.168.1.10:7272,example.duckdns.org:7272"
        + "&fp=5b9e49f93a15f5ce0301f678ff2ac1b38a98fbec8824712bacb795fff6689ced&i=yz0j33u5l-TfL7K6mf-6yJK1QdCNR9vn14ZUbLYLoZs"

    #if canImport(CoreImage)
    /// Texts of 1 to 1 000 bytes, accents and emoji, and an invitation.
    nonisolated static let texts = [1, 17, 30, 100, 300, 1000].map(sample) + [
        "Les BD de Léa : Astérix, L’Arabe du futur, Blacksad — « à lire » 📚✨🇫🇷 漫画とコミック",
        invitation,
    ]

    /// Every text at every level, read back as it was written.
    @Test(arguments: [QRCode.Correction.low, .medium, .quartile, .high])
    func scansWithCoreImage(at correction: QRCode.Correction) throws {
        let options = [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: options))
        for text in Self.texts {
            let code = try QRCode(text, correction: correction)
            #expect(try Self.scan(code, with: detector) == text, "\(text.utf8.count) bytes, version \(code.version)")
        }
    }

    /// The code drawn in grey levels, 8 pixels a module and a quiet zone of 4 modules, then decoded.
    static func scan(_ code: QRCode, with detector: CIDetector, scale: Int = 8) throws -> String? {
        let side = (code.size + 8) * scale
        var pixels = [UInt8](repeating: 255, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let column = x / scale - 4, row = y / scale - 4
                if (0..<code.size).contains(column), (0..<code.size).contains(row), code[column, row] { pixels[y * side + x] = 0 }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(), provider: provider,
                                         decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
    #endif

    /// `length` characters of a URL's alphabet, always the same ones.
    nonisolated static func sample(_ length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/?#[]@!$&'()*+,;=%")
        var seed = length
        return String((0..<length).map { (_: Int) -> Character in
            seed = (seed * 1_103_515_245 + 12345) & 0x7FFF_FFFF
            return alphabet[(seed >> 16) % alphabet.count]
        })
    }
}
