import Foundation
import Testing
@testable import CoolReaderKit

/// 7-Zip archives made with 7-Zip itself (the files below, coded four ways), read back by `SevenZipArchive`.
struct SevenZipArchiveTests {
    /// What every fixture holds.
    nonisolated static let expected: [String: Data] = [
        "001.txt": Data(String(repeating: "Cool Reader reads 7-Zip. ", count: 300).utf8),
        "002.bin": Data((0..<4096).map { (i: Int) -> UInt8 in UInt8(truncatingIfNeeded: i * 7 + i / 13) }),
        "sub/003.txt": Data(String(repeating: "The end.\n", count: 50).utf8),
    ]

    /// `7zz a -t7z -mx=9`: one solid LZMA2 folder, the header packed with LZMA.
    nonisolated static let solidLZMA2 = fixture("""
        N3q8ryccAARWdOC3LQIAAAAAAAAjAAAAAAAAACQVWovgLw0BnF0AIZvs2CApGNkxM3RAgwDBOxhywmcmEVhGn46SFNGk/m0sdHCt
        YDTiQ5xcTbmwwd6ooprOIArHZN+6tG94InEehFzn/gSNIBqbcvpkayw7T2srio+ohCm7zT2wBgs9jNTeCYv2Ixx9jhC8SBWB7r5X
        RBqGaf20mPMtErk3M796vfXlG1gHXeHx2O5TwaFaHF3E87+sYFNpLyvhD6PJvV8xi/FWmgJd4ZyMa4r6RZR4fmgyqztG0UB0JK95
        TmTIfLd1YGuBnHsZcTxYVrpNInZYj9NGNTx30bcm2ork5HfQllSooJdKZzaLWTsX744bqL1VcbiPXptkOZH8axIIzA2bgHUeziQS
        NfMYbhZAwXT+iS4YEOcKMJF5MPuHtZcs3Koj3Gc1Iqg/ryA3t7kQboJFgrkJuHzVNzAP5w4KjihKX8LZI6kC9BYtmPtwYlOZ3J0C
        VVegUicgzvWsZQDT1w+GevcLCB3FTzAtOHfCvgeE+4l828O3vsWaKsTr5n2dzv9RUzajpmgzHw0pSNe2J33hgxbb0zRQ/d5OGvSk
        AAAAAIEzB64P1Tt0Khck0/6zcBaxV6Nce/guv2d8nLE5YLXYQ4L75iqd9FW+0Oaq2XN8JoS9mQfNynPknVTFJkKM3uDmOIqJJhkv
        8uaSAWOaIh3NXuEt7yILN2HxInoYjGjhU3fXZgUFhkD80Jte3BKw/hea6HjKrmH6mfTI2x0dEFROZflhXx0AABcGgaQBCYCJAAcL
        AQABIwMBAQVdABAAAAyAvgoBpHGKOQAA
        """)

    /// `7zz a -t7z -m0=lzma -ms=off -mhc=off`: an LZMA folder per file, a plain header.
    nonisolated static let nonSolidLZMA = fixture("""
        N3q8ryccAARaW1IArwEAAAAAAADeAAAAAAAAAAhhN84AIZvs2CApGNkxM3RAgwDBOxhywmcmEVhGn46SFNGk/m0sdHCtYDTiQ5xc
        Tbmwwd6ooprOIArHZN+6tG94IiAAAAACD1cCaMZ4ztgPkObrtvt85ig/1+laQZWPfTHJ69NDdo0RxhWiTcXBQrL/YJYvX0GR2Bex
        l1HklrXf5wZpDvHbErlYqBfxaBvyu0228dZz1RCrHTZuFWVTUVMJctWkpOt3kH5kuu6QlyCrzt5twwT0nM41xnVDY0du8BXCSmSE
        dqh+hv53UxJfdy7YOJOj+oSVFHo/q+wynDD4o27cnlfhWTiVF1OKDVBSSDDoo1rdO54n96XSf4Ypb2eYaHEsGuCEGolGHKS1upjG
        6MWar4SyCxy5V2l+kNRqfQQFh01//5jVBjiOAWWq2aUMmySowrXaBlGtQsSmnKcEAnWMbFFWLvE9RZMcoiCO5Gi3sOcUnchBFvXz
        Hwxpu01PdhuWjV6SyIOUJlE/Hn8K6qhVY/2+VOrT/UKlGHG6OYlxdDohDgm60iCki3TAB9d0BpRJCyqJdq/XqDTv5KgAACoaCKIC
        wl8dc/utof4ZdCwAAAEEBgADCUCBXBMABwsDAAEjAwEBBV0AIAAAASMDAQEFXQAgAAABIwMBAQVdACAAAAydTJAAgcIACAoBDqLr
        djBV+Z0MvVwtAAAFBA4BgBkNAAAAAAAAAAAAAAAAABFBAHMAdQBiAAAAMAAwADEALgB0AHgAdAAAADAAMAAyAC4AYgBpAG4AAABz
        AHUAYgAvADAAMAAzAC4AdAB4AHQAAAAZAgAAFCIBAHZfdZspa90B51J1mylr3QEAXnWbKWvdAY1gdZspa90BFRIBABCA7UEggKSB
        IICkgSCApIEAAA==
        """)

    /// `7zz a -t7z -m0=deflate`.
    nonisolated static let deflate = fixture("""
        N3q8ryccAATOPwAIxAIAAAAAAAAjAAAAAAAAAP6iM2zt02VTlVEYhWFsxFbsem0Mji0GJnYiYiEGel4FRc7xYHdgd2N3Yxc2dmF3
        Y7fSnfPMrP0fGNanvWfWp2vueZxMJm/NRfcw6hbNkvb4ag72bl5mg8aBAwcOHDhw4MCBAwcOHDhw4MCBAwcOHDhw4MCBAwcOGXiw
        ypG3cKkK1Wo3bN62i6v7kOGjxk+bs3jVhu37jgReunHv6ZtPP0NjkrPlti1Zvmoth2ZtOvdw8/A0j5s6e9HK9dv2Hj514Vrwk9cf
        f/yPTsqaq2Bxza5mg6atO7n0HTTMZ8xkv4Ur1m3dc+jk+at3Hr0M+f4vKjGLTYFiZSvb13N06ti9z8ChI0dPmjl/mf+W3QdPnLty
        ++GL91//RCZkzpm/aJlKNeo2btneufcA3dt34ox5S9ds2hlw/OzlWw+ev/vyOzzOyjpfkdIVq9dp1KJd157uxhGWCdPnLlm9ccf+
        o4FBN+8/e/v5V1hsSvY8tgrWb7CXWcFOX7werGCFSpSzUzDT2Cl+Cnb38asQBatiqO+oYLMWLPdXsA/f/kYqWJNWHZwVbO3mXQEK
        FhGfyVrBuvXqb1SwA8fOBAEmNQCTGoBJDcCkBmBSAzCpAZjUAExqACY1AJMagEkNwKQGYFIDMKkBmNQATGoAJjUAkxqASQ3ApAZg
        UgMwqQGY1ABMagAmNQCTGoBJDcCkBmBSAzCpAZjUAExqACY1AJMavB/eD++H98P74f3wfng/vB/eD++H95Ne7sfVU9d0H6PBhp90
        +kkFAACBMweuD9VEIQPXJNP+spd6wRPptJsatZyBmt8L0MS/uu84XEByisfSGaVqNWsygz3uo6vfKYZhabtca3aqDNSHdbV273F7
        h1clPgG4Vzkxns0o9NnrA52GsnxBoYnHmVsv2iZLrL38taouPWQTP2j7nO5wyd/Wn6Z7NHZH9ehpehfSGeYAAAAXBoI7AQmAiQAH
        CwEAASMDAQEFXQAQAAAMgL4KAR4TQ1YAAA==
        """)

    /// `7zz a -t7z -m0=copy sub`: stored.
    nonisolated static let stored = fixture("""
        N3q8ryccAATew5qHJAIAAAAAAAAhAAAAAAAAAM3B1GtUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5k
        LgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpU
        aGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUg
        ZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5k
        LgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpU
        aGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUg
        ZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgpUaGUgZW5kLgoAAIEzB64P1TweWZck0/65xON0mJPTljAtdXI5CAin+N8LlsoCi/y2uRAa
        HG5TPZBmYZtGyxdorSbqPWSPrSVCdNsg52B5mLz4sM9q9BMSRrnRcx6dfbm72e2C+V/lLUAAABcGgcIBCWIABwsBAAEjAwEBBV0A
        EAAADHYKAW3eaQYAAA==
        """)

    nonisolated private static func fixture(_ base64: String) -> Data {
        Data(base64Encoded: base64, options: .ignoreUnknownCharacters)!
    }

    @Test(arguments: [solidLZMA2, nonSolidLZMA, deflate])
    func readsEveryFile(archive data: Data) throws {
        let archive = try SevenZipArchive(data: data)
        let files = archive.entries.filter { !$0.isDirectory }
        #expect(Set(files.map(\.path)) == Set(Self.expected.keys))
        for entry in files {
            #expect(try archive.data(for: entry) == Self.expected[entry.path])
        }
        #expect(archive.entries.contains { $0.path == "sub" && $0.isDirectory })
    }

    @Test func readsStoredFiles() throws {
        let archive = try SevenZipArchive(data: Self.stored)
        let entry = try #require(archive.entry(atPath: "sub/003.txt"))
        #expect(try archive.data(for: entry) == Self.expected["sub/003.txt"])
    }

    /// In a solid folder a later file comes first; the earlier ones come from the cache, or a fresh decoder.
    @Test func readsSolidFilesInAnyOrder() throws {
        let archive = try SevenZipArchive(data: Self.solidLZMA2)
        for path in ["sub/003.txt", "001.txt", "sub/003.txt", "002.bin", "001.txt"] {
            #expect(try archive.data(atPath: path) == Self.expected[path])
        }
    }

    @Test func rejectsDamagedData() throws {
        var damaged = Self.nonSolidLZMA
        damaged[damaged.startIndex + 40] ^= 0x55
        let archive = try SevenZipArchive(data: damaged)
        #expect(throws: ArchiveError.self) {
            for entry in archive.entries where !entry.isDirectory { _ = try archive.data(for: entry) }
        }
    }

    /// Comic archives open by what they are, whatever their extension says.
    @Test func opensArchivesByTheirContent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = folder.appendingPathComponent("zip.cbr")
        try TestZip.make([TestZip.File(name: "1.png", data: Data([1, 2, 3]))]).write(to: zip)
        #expect(try BookOpener.archive(url: zip, format: .cbr) is ZipArchive)
        let sevenZip = folder.appendingPathComponent("7z.cbz")
        try Self.solidLZMA2.write(to: sevenZip)
        #expect(try BookOpener.archive(url: sevenZip, format: .cbz) is SevenZipArchive)
    }
}
