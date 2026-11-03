import Foundation
import Testing
@testable import CoolReaderKit

/// Raw DEFLATE streams and a ZIP archive made by zlib (Python's), read back by `Inflate` and `ZipArchive`.
struct InflateTests {
    nonisolated static let text = Data(String(repeating: "Cool Reader Server reads ZIP. ", count: 400).utf8)
    nonisolated static let pattern = Data((0..<5000).map { UInt8(($0 * 7 + $0 / 13) & 0xFF) })
    /// 1 200 bytes of noise, from the same generator as the fixture's.
    nonisolated static let noise: Data = {
        var x = 12345
        var bytes: [UInt8] = []
        for _ in 0..<1200 {
            x = (x * 1_103_515_245 + 12345) & 0x7FFF_FFFF
            bytes.append(UInt8((x >> 16) & 0xFF))
        }
        return Data(bytes)
    }()

    /// `compressobj(0, DEFLATED, -15)`: stored blocks.
    nonisolated static let stored = fixture("""
        AbAET/vcBGWqH60dWtrlrBseXxNweWz9EP8Zr2AdBKy0HQIrRnhzOvLfX663CFnR7jkQy0iVtcyJKRH/BrZiLt88+TX9S5Qoygl8
        RLMCXpZfs+ptrNQtgW5pr+Dmh0ycBOfSNl0sYMnq9Hn2hqDrkybkYhLVDcuzdxVqajpouo7bdAhGnvPOswr40N1ou/hf+iTy0vwY
        h/tch7q0ODKlmxs9EHz3eNZ/4m34EZEpfpOVyxLFV85a8dQWGNcZvARbfpll8aKUccQqrGqpOMR1x60yOAIfBTssmRr86xXez2i6
        4Hy81h6XG5oLnb6XY9OS/K/fooyXI0Vi690HZXD/WIlqz/fK7j8c6eQKaOXek404nH2911sJ1OfiM0Q/SozEoZDWuLjcYV/Rjii+
        WQ6qUBtQimo2KeZw31V3utxEbUO7qQgX1sD2ewhhcNktyRJyWyR+wuLasbIEniCAdDeab5AM3S5ecvUJSLZY0Zfpw4yxbtPdEkRi
        MgwUp68/+gze1hPOE4bLV6BH5Fu+0UW0NtWI/tIAQfKHsQ+DX3RluihGFlLfiKIT2b9C77cRtd4Hf8l5uuOoWEqp6C2oTVCd5phr
        4qmazyFMZiqM1ZARN5hnibut81GNE631HKEBlKywhGz1ivUqepH186svhjK6gUUgPcNnFIh6dZDIY8cH4B7CcAOa0YsWPyT2w94r
        711a0eZ2E3nKQha5EKoF2YMwxwrPhfBmy+zvrIlM+rcfGLrDNN+2YEqygDLNOaFu35REFOHzpuzB9DlDBsCbYp3jOtNh78NTa9BP
        lh/uTb3zBS2X/sTRm0UntKLElNhkPrhxucQfU4sIlRyeX0Ah/5d6Gk1/cIyrL3z6gBtCyvXbjPksuOZ+Qfb5fwHkqDZtpOyi7bpw
        7VRX66CXY0GJTU1ZaOaSvFyrDvMQeQadpT3xUl0uCTsNzpZtQZ71CiykaxZWnawaBAIpe2a9HZeDqFal5crDSQRQwvpzTSgUzDEN
        vF0LXHiPfh6KGoWBD+vmq9zQd0EU6RS1ic9cU9iBLgtDE+b8TBVXxRfEiIp98y/I77fv2RHVUEYS7ILQzWLRPaEQ6OMRrcb2GvuA
        kVizu4XXMejluuA+To5jefdriVR80O7HajxwAImMWCPtGEXCu4zYG7yGIRSj9Mz3HisL7Z/IQzznR3ZAV2VzK/Y1v3xBBEJAtu6x
        DB89v7afhQPWfYCn/7Sq1r02nONOBCk6Ie86BxAraahcmWDTbNHwh0Xx8LTIJ9yprwApQUZvac3pnSPAQXRwHT3pVqHSDOSwc9AR
        AE+bVQdOjAUlyZBvkgskuQWM53op5+cVwaGo2pWY89skTGWOCNGzJyeQvrOewVr0bqneAOSTa5jKj/1JUO0zRLd33v7DckuI3lNR
        qwxCGcuST7B5ZndO1VVVZKn3qGdHU4hfHlFnLh/jyqHS8sU4Ngo4tV3GzGfE+qszc6ICZ9mNNz5lyeoz5M2tBp5phI8ubhtGJR3K
        jl5QScQfajIL9AA81UxEMTLQNrTZh4m196tWsLlIgqibmvDnbiRnciyQQk58Stp2A9q0l3AFaZFGo1muaD8PoGZxcj2K+rH5oKTs
        J4nXo+8=
        """)

    /// `compressobj(9, DEFLATED, -15, 9, Z_FIXED)`: the fixed Huffman codes.
    nonisolated static let fixed = fixture("""
        c87Pz1EISk1MSS1SCE4tKgNSRUBesUKUZ4CegvOo7KjsqOyo7KjsqOyo7KjsqOyo7KjsqOyo7KjsqOyo7KjsqOyo7KjsqOyo7Kjs
        qOyo7KjsqOyo7KjsqOyo7KjsqOyo7KjsqOyo7KjsqOyo7KjsqOyo7KjsqOyoLF1kAQ==
        """)

    /// `compressobj(9, DEFLATED, -15)` of the text then the pattern: dynamic Huffman codes.
    nonisolated static let dynamic = fixture("""
        7ZNFVJQBGEWxsQPs4BcLC7sxR1HMEcRADHTGRAcHxU6wA2zsFgPswMYu7G7sbuzkbd7alau3+s537uqee57JZgs0vK0BFqvd8LHa
        Q5KOPekLNvy8zO6GSVRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVPS/UIc0mbLnK1SiXNXans1a
        +Xft1W/QyHFTZy1YvnZT7IFjZy7fevD83ZffqTI453UtXrZKrQZNffwCegQNHDF2ysz5y9Zs3LHvSPylm/efvf38K2X6bLkNtzKV
        a9Zv4t2uc/e+A4aFTZ4xb2nUhu17D5+6cD3h6ZtPP1Oky5rLpWjpih6mxi3bdurWp//QMRMjIpesjtm259DJ89fuPn6V+CN52iw5
        CxQpVaF63UbmNh2tgcFDRk8In7NoZfTW3QdPnLt659HLD98cHDPnyF+4ZPlqdRo29/W39LYPHjV+2uyFK9Ztjo07fvbK7Ycv3n/9
        kzqjM8Xad+kZRLGd+4/GU8wpT0E3itlChodR7PTFGwkUK+ZeyYNioZOmR1Ls3pPXiRSrUc/LTLG5i1dFU+zj92SOFGvRuoOFYuu3
        7IqjGGpQDDUohhoUQw2KoQbFUINiqEEx1KAYalAMNSiGGhRDDYqhBsVQg2KoQTHUoBhqUAw1KIYaFEMNiqEGxVCDYqhBMdSgGGpQ
        DDUohhoUQw2KoQbFUINiqEEx1KAYalAMNbQf7Uf70X60H+1H+9F+tB/tR/vRfrQf7Uf70X7+dT9/AQ==
        """)

    /// Python's `zipfile` with ZIP_DEFLATED: « pages/page 10.txt » holds the text, « pages/page 2.txt » the pattern.
    nonisolated static let zip = fixture("""
        UEsDBBQAAAAIAOZtY10oYiN3UQAAAOAuAAARAAAAcGFnZXMvcGFnZSAxMC50eHTtybEJgEAQAMFWrgKb+MhMNPtM8DLh4QTr96sw
        mmhZpo1xx57nlRVH1jtT857o67ZEo5RSSimllFJKKaWUUkoppZRSSimllFJKKaWUUkp/0Q9QSwMEFAAAAAgA5m1jXTM4lUj3AQAA
        iBMAABAAAABwYWdlcy9wYWdlIDIudHh07dNnNxdgAIbxf2koWkjS0ETJLFqKUiolUtFAQguhXRpGyEoZyYzSTkYaUiQailKRQoP2
        oiVN5dxv7td9gOcj/M51Lkn7zt17DxyqO8rI1HyOrZPLqo3egTujEw4cy8y5dO1WRc2zt5++/20rq9BrwBCdkeMnz5i9YPFyzw3b
        AsKi4vcfzTibd6W0vLruzcem5jYycj37qWsbjJs03Wq+wzL3dVv8QyPjUo6kn7lYdPPuw9rXDd/+SHXspqSiqjnC0MRs1rxFS1eu
        3ewXvDs2+fDJ0xcKb9x58OTlh8bfrTt07dF38LDhYyZMtbSxX+K2xss3aFdM0sG07NzLxWWVj1+8//JTIt1Fsc8gDb3RxlNmzrV1
        dl29yWdH+J7E1ONZOQXXb99/9Pzd5x//2nVSIGyh4wpPws7lXy0lTF65vzphHuu3+hNWcq+qljA1LX1DwraHRMQS9vRVfSNhYydO
        syRs775DaYR9/dVKmjALaztnwk6cOl9AGGoQhhqEoQZhqEEYahCGGoShBmGoQRhqEIYahKEGYahBGGoQhhqEoQZhqEEYahCGGoSh
        BmGoQRhqEIYahKEGYahBGGoQhhqEoQZhqEEYahCGGoShBmGoQRhqEIYaEvGP+Ef8I/4R/4h/xD/iH/GP+Ef8I/4R/4h/xD/in//8
        pwVQSwECFAMUAAAACADmbWNdKGIjd1EAAADgLgAAEQAAAAAAAAAAAAAAgAEAAAAAcGFnZXMvcGFnZSAxMC50eHRQSwECFAMUAAAA
        CADmbWNdMziVSPcBAACIEwAAEAAAAAAAAAAAAAAAgAGAAAAAcGFnZXMvcGFnZSAyLnR4dFBLBQYAAAAAAgACAH0AAAClAgAAAAA=
        """)

    nonisolated private static func fixture(_ base64: String) -> Data {
        Data(base64Encoded: base64, options: .ignoreUnknownCharacters)!
    }

    private func inflate(_ data: Data, size: Int) throws -> Data {
        try data.withUnsafeBytes { try Inflate.decode($0, expectedSize: size) }
    }

    @Test func readsStoredBlocks() throws {
        #expect(try inflate(Self.stored, size: Self.noise.count) == Self.noise)
    }

    @Test func readsFixedCodes() throws {
        #expect(try inflate(Self.fixed, size: Self.text.count) == Self.text)
    }

    @Test func readsDynamicCodes() throws {
        #expect(try inflate(Self.dynamic, size: Self.text.count + Self.pattern.count) == Self.text + Self.pattern)
    }

    @Test func rejectsDamagedStreams() throws {
        var damaged = Self.dynamic
        damaged[damaged.startIndex + 40] ^= 0x55
        #expect(throws: ArchiveError.self) { try inflate(damaged, size: Self.text.count + Self.pattern.count) }
        #expect(throws: ArchiveError.self) { try inflate(Self.dynamic.prefix(200), size: Self.text.count + Self.pattern.count) }
    }

    @Test func readsDeflatedZipArchives() throws {
        let archive = try ZipArchive(data: Self.zip)
        #expect(try archive.data(atPath: "pages/page 10.txt") == Self.text)
        #expect(try archive.data(atPath: "pages/page 2.txt") == Self.pattern)
    }
}

struct BookFileTests {
    @Test func decodesCodePage437() {
        #expect(CP437.decode(Data([0x90, 0x76, 0x61, 0x73, 0x69, 0x6F, 0x6E, 0x81])) == "Évasionü")
    }

    @Test func ordersPagesNaturally() {
        let names = ["Page 10.jpg", "page 2.jpg", "Page 1.jpg", "écran 3.jpg", "ecran 20.jpg", "Page 01b.jpg"]
        #expect(names.sorted(by: NaturalOrder.less) == ["écran 3.jpg", "ecran 20.jpg", "Page 1.jpg", "Page 01b.jpg", "page 2.jpg", "Page 10.jpg"])
        #expect(NaturalOrder.less("page 2.jpg", "Page 10.jpg"))
        #expect(NaturalOrder.less("écran 3.jpg", "ecran 20.jpg"))
        #expect(!NaturalOrder.less("Page 10.jpg", "page 9.jpg"))
    }

    /// A CBZ's pages in natural order, its cover, and its ComicInfo.xml.
    @Test func analysesComicArchives() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let comicInfo = """
            <?xml version="1.0"?>
            <ComicInfo><Series>Blacksad</Series><Number>7</Number><Writer>Juan Díaz Canales</Writer><Manga>No</Manga></ComicInfo>
            """
        let url = folder.appendingPathComponent("Blacksad 07.cbz")
        try TestZip.make([
            TestZip.File(name: "10.jpg", data: Data([1])),
            TestZip.File(name: "2.jpg", data: Data([2])),
            TestZip.File(name: "__MACOSX/._2.jpg", data: Data([3])),
            TestZip.File(name: "ComicInfo.xml", data: Data(comicInfo.utf8)),
        ]).write(to: url)
        let analysis = try BookAnalysis.analyze(url: url, format: .cbz)
        #expect(analysis.pagePaths == ["2.jpg", "10.jpg"])
        #expect(analysis.coverPath == "2.jpg")
        #expect(analysis.metadata?.series == "Blacksad")
        #expect(analysis.metadata?.number == 7)
        #expect(analysis.metadata?.writers == ["Juan Díaz Canales"])
        #expect(analysis.metadata?.isRightToLeft == false)
    }

    @Test func rejectsArchivesWithoutPages() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cbz")
        defer { try? FileManager.default.removeItem(at: url) }
        try TestZip.make([TestZip.File(name: "notes.txt", data: Data("hi".utf8))]).write(to: url)
        #expect(throws: BookOpenError.empty) { try BookAnalysis.analyze(url: url, format: .cbz) }
    }
}

/// Stored ZIP archives, written by hand.
enum TestZip {
    struct File {
        let name: String
        let data: Data
    }

    static func make(_ files: [File]) -> Data {
        var archive = Data()
        var directory = Data()
        for file in files {
            let name = Data(file.name.utf8)
            let offset = UInt32(archive.count)
            let crc = CRC32.checksum(file.data)
            archive.append(le32(0x0403_4B50))
            archive.append(le16(20)); archive.append(le16(0x0800)); archive.append(le16(0))
            archive.append(le16(0)); archive.append(le16(0)); archive.append(le32(crc))
            archive.append(le32(UInt32(file.data.count))); archive.append(le32(UInt32(file.data.count)))
            archive.append(le16(UInt16(name.count))); archive.append(le16(0))
            archive.append(name); archive.append(file.data)

            directory.append(le32(0x0201_4B50))
            directory.append(le16(20)); directory.append(le16(20)); directory.append(le16(0x0800)); directory.append(le16(0))
            directory.append(le16(0)); directory.append(le16(0)); directory.append(le32(crc))
            directory.append(le32(UInt32(file.data.count))); directory.append(le32(UInt32(file.data.count)))
            directory.append(le16(UInt16(name.count))); directory.append(le16(0)); directory.append(le16(0))
            directory.append(le16(0)); directory.append(le16(0)); directory.append(le32(0)); directory.append(le32(offset))
            directory.append(name)
        }
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.append(le32(0x0605_4B50))
        archive.append(le16(0)); archive.append(le16(0))
        archive.append(le16(UInt16(files.count))); archive.append(le16(UInt16(files.count)))
        archive.append(le32(UInt32(directory.count))); archive.append(le32(directoryOffset)); archive.append(le16(0))
        return archive
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}
