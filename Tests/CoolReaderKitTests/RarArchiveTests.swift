import Foundation
import Testing
@testable import CoolReaderKit

/// RAR 5 archives made with RAR 7.23 itself (the files below, coded several ways), read back by `RarArchive`.
/// RAR 7 no longer writes RAR 4 archives: that format was checked against real ones, which can't be committed.
struct RarArchiveTests {
    /// What every fixture holds.
    nonisolated static let expected: [String: Data] = [
        "001.txt": Data(String(repeating: "Cool Reader reads RAR. ", count: 300).utf8),
        "002.bin": Data((0..<4096).map { (i: Int) -> UInt8 in UInt8(truncatingIfNeeded: i * 7 + i / 13) }),
        "sub/003.txt": Data(String(repeating: "The end.\n", count: 50).utf8),
        "sub/empty.txt": Data(),
    ]

    /// `rar a -m3`.
    nonisolated static let nonSolid = fixture("""
        UmFyIRoHAQDz4YLrCwEFBwAGAQGAgIAAyB2wjiUCAwuzAAT0NaSDAqrVZ72AAwEHMDAxLnR4dAoDE/K06WoS4i8AxqwwJTUz+kJK
        /QWQ+Mg6g8GvPBQtf/W1LxAwnnRyI+mfvnlTkq822kMrD4w+MPjD4w+MArLnlCsCAwuAAASAAKSDAgAAAACAAAENc3ViL2VtcHR5
        LnR4dAoDE/K06WoQkjIA5e8qVCUCAwugAASAIKSDAjBV+Z2AAwEHMDAyLmJpbgoDE/K06WocGTEAwYYdQ0L8Ii/2IFkAOIf7cvWm
        gAgAgAKeZwh+h+kw6wDp85g3KQIDC5wABMIDpIMCDL1cLYADAQtzdWIvMDAzLnR4dAoDE/K06WrgIzIAxoUZMwI/sy/yKyCE0IQJ
        Dof6gEFeq6jH7qHbeB13VlEDBQQA
        """)

    /// `rar a -s -ds -m5`: one solid stream, through the empty file, which has no packed data.
    nonisolated static let solid = fixture("""
        UmFyIRoHAQAJ78hvCwEFBwQGAQGAgIAA5zt3FiUCAwu8AAT0NaSDAqrVZ72AHQEHMDAxLnR4dAoDE/K06WoS4i8AxKc5NmVB+jNc
        wrsCYOjA0YCkdIoQkN5K1RWwpT3rOp73/20OtahPOMjuV++xyGvYQZWD4wfGD4wfGD4wmfijaisCAwuAAASAAKSDAgAAAADAHQEN
        c3ViL2VtcHR5LnR4dAoDE/K06WoQkjIAwQsTBSUCAwuTAASAIKSDAjBV+Z3AHQEHMDAyLmJpbgoDE/K06WocGTEARQ8Q2ACACAAr
        XvZThCfoT9CfoPRCb08pAgMLiwAEwgOkgwIMvVwtwB0BC3N1Yi8wMDMudHh0CgMT8rTpauAjMgBBEwiEzI6yYv++AB13VlEDBQQA
        """)

    /// `rar a -mce+`: the x86 filter (and the delta filter, which RAR still picks for `002.bin`).
    nonisolated static let x86Filter = fixture("""
        UmFyIRoHAQDz4YLrCwEFBwAGAQGAgIAAVTDXOCUCAwu5AAT0NaSDAqrVZ72AAwEHMDAxLnR4dAoDE/K06WoS4i8Awa02JkYy+lKK
        /wJg6MD0DQd5oYM38Hy2i/QHjvrR8AH0GjqI6mffHlTc9WZbCGVh8YfGHxh8YfGAArLnlCsCAwuAAASAAKSDAgAAAACAAAENc3Vi
        L2VtcHR5LnR4dAoDE/K06WoQkjIA5e8qVCUCAwugAASAIKSDAjBV+Z2AAwEHMDAyLmJpbgoDE/K06WocGTEAwYYdQ0L8Ii/2IFkA
        OIf7cvWmgAgAgAKeZwh+h+kw6wBHGo8eKQIDC6IABMIDpIMCDL1cLYADAQtzdWIvMDAzLnR4dAoDE/K06WrgIzIAxIEfMwI/sy/y
        KyCyayECQ6H/4JgQV6rqgAOEAn0dLHZd4B13VlEDBQQA
        """)

    /// `rar a -mc3d+`: the delta filter, three byte channels.
    nonisolated static let deltaFilter = fixture("""
        UmFyIRoHAQDz4YLrCwEFBwAGAQGAgIAA5DjcUiUCAwvNAAT0NaSDAqrVZ72AAwEHMDAxLnR4dAoDE/K06WoS4i8Ax9dKJABC+jJz
        clQd3BBgTA0Hdm3xRgCfA3VhagsBYj8A/4J0A6QcdLvgA+g0BY0tXmvkNh4zs43huo0y5GRkfGA/8EpZHxgP/BKWR8YCsueUKwID
        C4AABIAApIMCAAAAAIAAAQ1zdWIvZW1wdHkudHh0CgMT8rTpahCSMgCo4xfHJQIDC7UABIAgpIMCMFX5nYADAQcwMDIuYmluCgMT
        8rTpahwZMQDBqTIzAy+yM//1AWLFkggWcTpDTN0mRW6bpbK+8XeJsAEAEAJo2P2raAoK9hzZQqRIR1r8ALbgBuQpAgMLqQAEwgOk
        gwIMvVwtgAMBC3N1Yi8wMDMudHh0CgMT8rTpauAjMgDDvyZFBR+zLBAUYdyQpQ7mzNBGyStX4ihHu9buABwgECpLP4XJcEa0gB13
        VlEDBQQA
        """)

    /// `rar a -m0 sub/003.txt sub/empty.txt`: stored.
    nonisolated static let stored = fixture("""
        UmFyIRoHAQDz4YLrCwEFBwAGAQGAgIAAmLRPeikCAwvCAwTCA6SDAgy9XC2AAAELc3ViLzAwMy50eHQKAxPytOlq4CMyAFRoZSBl
        bmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQu
        ClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRo
        ZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBl
        bmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQu
        ClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRo
        ZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuClRoZSBlbmQuCgKy55Qr
        AgMLgAAEgACkgwIAAAAAgAABDXN1Yi9lbXB0eS50eHQKAxPytOlqEJIyAB13VlEDBQQA
        """)

    /// `rar a -oi1:1 -ds`, with `004.bin` a copy of `002.bin`: saved as a reference to it.
    nonisolated static let references = fixture("""
        UmFyIRoHAQDz4YLrCwEFBwAGAQGAgIAAyB2wjiUCAwuzAAT0NaSDAqrVZ72AAwEHMDAxLnR4dAoDE/K06WoS4i8AxqwwJTUz+kJK
        /QWQ+Mg6g8GvPBQtf/W1LxAwnnRyI+mfvnlTkq822kMrD4w+MPjD4w+MArLnlCsCAwuAAASAAKSDAgAAAACAAAENc3ViL2VtcHR5
        LnR4dAoDE/K06WoQkjIA5e8qVCUCAwugAASAIKSDAjBV+Z2AAwEHMDAyLmJpbgoDE/K06WocGTEAwYYdQ0L8Ii/2IFkAOIf7cvWm
        gAgAgAKeZwh+h+kw6wDp85g3KQIDC5wABMIDpIMCDL1cLYADAQtzdWIvMDAzLnR4dAoDE/K06WrgIzIAxoUZMwI/sy/yKyCE0IQJ
        Dof6gEFeq6jH7qHbeJ2ajs4xAgMXgAAEgCCkgwIAAAAAgAABBzAwNC5iaW4KAxPytOlqu/xpBgsFBQAHMDAyLmJpbh13VlEDBQQA
        """)

    /// `rar a -s -ds -md128k -mc3d+ 001.txt wrap.bin 002.bin`: 300 KB through the smallest window, filtered.
    nonisolated static let smallWindow = fixture("""
        UmFyIRoHAQDGWuDQDAEFCAQHAQGAgICAAOQ43FIlAgMLzQAE9DWkgwKq1We9gAMBBzAwMS50eHQKAxPytOlqEuIvAMfXSiQAQvoy
        c3JUHdwQYEwNB3Zt8UYAnwN1YWoLAWI/AP+CdAOkHHS74APoNAWNLV5r5DYeM7ON4bqNMuRkZHxgP/BKWR8YD/wSlkfG8qAWmSgC
        AwvMhQAE4KcSpIMCPtQEd8ADAQh3cmFwLmJpbgoDE/K06Wr2C24Gh/QpMjP8Mq/3Tsnjwg7uAEAAACBVZcV5XleV5XleV5XleV5X
        leV5XleV5W2D/CUCL9Iv/6mzlShA9mltLyXkvJeS8l5LyXkvJeS8l5LyXkvJeS1gg/ApQj/UHs/uOFoBguGL1FV6rWovBeC8F4Lw
        XgvBeC8F4LwXgvBeC8F4LUCF7TICA/wxf1rAuFd5oAgyGL6JqAEAAACBTB2P6wvBeC8F4LwXgvBeC8F4LwXgvBeC8F4LYIf3KgJD
        /EEmz+t730AwXDFF++20oCLwXgvBeC8F4LwXgvBeC8F4LwXgvBeC1IX2KQIz/CL39Hv6tABxEiKBL/o+r0Xl4XheF4XheF4XheF4
        XheF4XheF4WogOkzAgP8MVfP4Rhbd6AYLhiA4hoAQAAAIFNttHgReC8F4LwXgvBeC8F4LwXgvBeC8F4LwWwAgfMoAj/TESz+14Av
        oOhiA4hsuuxkXheF4XheF4XheF4XheF4XheF4XhagIf2KwJE/DF/SfN/06AIQhS2ibcOserC8F4LwXgvBeC8F4LwXgvBeC8F4LwX
        gtSD9i8CA/wxfxbJOEt/r6DoYgKIqACGcoFMXXfZB4HgeB4HgeB4HgeB4HgeB4HgeB4HQITyLEJE/EF/OOSO97kAQZDEBxDuG09W
        B4DwHgPAeA8B4DwHgPAeA8B4DwHgPAcggPctQkP8Ir+7X9OV/EBIeRQWSnfbEnAQeA8B4DwHgPAeA8B4DwHgPAeA8B4DwHIAgPYs
        QgP8QX3NmFd73QBBkMQFEVAB1K4CmDafwgUAoBQCgFAKAUAoBQCgFAKARgCE+CZCRPxBcOfxHvO5kAwVDNF++2420FAKAUAoBQCg
        FAKAUAoBQCgEYIP9JAIz/CKW+/1Dvw4iRFBpJ9yxuY8FAUBQFAUBQFAUBQFAUBQEQMeBHDMDL7Iz//UBYsWSCBZxOkNM3SZFbpul
        sr7xd4kAOF8rJQIDC5kABIAgpIMCMFX5ncADAQcwMDIuYmluCgMT8rTpahwZMQBBDRawAQAQAmjY/atoCgr2HNlCpEhHWvwAHXdW
        UQMFBAA=
        """)

    /// `wrap.bin`: three byte channels that climb slowly.
    nonisolated static let wrap: Data = {
        var bytes: [UInt8] = []
        for i in 0..<100_000 {
            let channels: [Int] = [i / 3, i / 5, 255 - i / 7]
            bytes.append(contentsOf: channels.map { UInt8(truncatingIfNeeded: $0) })
        }
        return Data(bytes)
    }()

    /// `rar a -psecret sub/003.txt`.
    nonisolated static let encrypted = fixture("""
        UmFyIRoHAQDz4YLrCwEFBwAGAQGAgIAAl/4ZjVoCAzygAATCA6SDAlKP6d6AAwELc3ViLzAwMy50eHQwAQADD4s99wHySCGrdUhv
        PjTdjGM0GMiq+TDHjP0zoKuzCVhHl1PkObIq1vQGzQcNCgMT8rTpauAjMgCATlsPsfpeNtqBzWdo5ervvnAV6dv4R4fiPP9O0iek
        Ih13VlEDBQQA
        """)

    /// `rar a -hpsecret sub/003.txt`: even the list of files is encrypted.
    nonisolated static let encryptedHeaders = fixture("""
        UmFyIRoHAQATt0kbIQQAAAEPUZcBu2kf19FhfUIytCEGCAFwod38p0rEYR0qwZ3WBH7lcj9RtYoamDhcx86dv1JlCvfSJPoqVELE
        2L2DN73VW7q82M27suYe2hnnlKLtYdsTDoJZpPleiE2OWqy5zlAjGyP3zf/ytMYRS4Y5nz0Dn7f/j8tdFgJXE80bsA02AcEChEPe
        qCP45sgHePU+YAGAUeHj2Gw0N0013TwMd8z5OwsQReHzpa8+V8zAYKxmyY5xI6RDPgCYsw35679mMnK9lx4CBMk0LsRush9H7Dm3
        j0Y8gu0fLvOQ2yDTQhD93vHAxUscoIf6tKtV6fQ=
        """)

    nonisolated private static func fixture(_ base64: String) -> Data {
        Data(base64Encoded: base64, options: .ignoreUnknownCharacters)!
    }

    @Test(arguments: [nonSolid, solid, x86Filter, deltaFilter])
    func readsEveryFile(archive data: Data) throws {
        let archive = try RarArchive(data: data)
        #expect(Set(archive.entries.map(\.path)) == Set(Self.expected.keys))
        for entry in archive.entries {
            #expect(try archive.data(for: entry) == Self.expected[entry.path])
        }
    }

    @Test func readsStoredFiles() throws {
        let archive = try RarArchive(data: Self.stored)
        #expect(archive.entries.map(\.method) == [0, 0])
        #expect(try archive.data(atPath: "sub/003.txt") == Self.expected["sub/003.txt"])
        #expect(try archive.data(atPath: "sub/empty.txt") == Data())
    }

    /// In a solid stream a later file comes first; the earlier ones come from the cache, or the stream again.
    @Test func readsSolidFilesInAnyOrder() throws {
        let archive = try RarArchive(data: Self.solid)
        for path in ["sub/003.txt", "001.txt", "sub/empty.txt", "002.bin", "sub/003.txt", "001.txt"] {
            #expect(try archive.data(atPath: path) == Self.expected[path])
        }
    }

    /// WinRAR can save a file identical to an earlier one as a mere reference to it.
    @Test func readsReferencesToIdenticalFiles() throws {
        let archive = try RarArchive(data: Self.references)
        let copy = try #require(archive.entry(atPath: "004.bin"))
        #expect(copy.compressedSize == 0)
        #expect(try archive.data(for: copy) == Self.expected["002.bin"])
    }

    /// Matches reach back across the end of the window, with the delta filter on.
    @Test func readsFilesLargerThanTheWindow() throws {
        let archive = try RarArchive(data: Self.smallWindow)
        #expect(try archive.data(atPath: "wrap.bin") == Self.wrap)
        #expect(try archive.data(atPath: "002.bin") == Self.expected["002.bin"])
        #expect(try archive.data(atPath: "001.txt") == Self.expected["001.txt"])
    }

    @Test func rejectsPasswords() throws {
        let archive = try RarArchive(data: Self.encrypted)
        #expect(archive.entries.map(\.isEncrypted) == [true])
        #expect(throws: ArchiveError.encrypted) { try archive.data(atPath: "sub/003.txt") }
        #expect(throws: ArchiveError.encrypted) { try RarArchive(data: Self.encryptedHeaders) }
    }

    @Test func rejectsDamagedData() throws {
        var damaged = Self.nonSolid
        // A byte of the packed data of 001.txt (66..<117).
        damaged[damaged.startIndex + 90] ^= 0x55
        let archive = try RarArchive(data: damaged)
        #expect(throws: ArchiveError.self) { try archive.data(atPath: "001.txt") }
        #expect(try archive.data(atPath: "002.bin") == Self.expected["002.bin"])
    }

    /// Comic archives open by what they are, whatever their extension says.
    @Test func opensArchivesByTheirContent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("rar.cbz")
        try Self.nonSolid.write(to: url)
        #expect(try BookOpener.archive(url: url, format: .cbz) is RarArchive)
    }
}
