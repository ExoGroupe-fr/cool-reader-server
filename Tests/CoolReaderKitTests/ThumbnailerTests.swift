import Foundation
import Testing
@testable import CoolReaderKit
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// Images shrunk into JPEGs: by ImageIO on the Mac, by libjpeg-turbo, libpng and libwebp on Linux (and on the Mac
/// with COOLREADER_SYSTEM_IMAGE_LIBS=1). Every fixture is cut in four quarters of plain colors: red, green, blue and
/// white unless said otherwise. The JPEGs were made with cjpeg 3.2 at quality 90 (the CMYK one with ImageIO, which
/// stores inverted inks like Photoshop), the WebPs with cwebp 1.6, the PNGs written by hand with Python's zlib.
struct ThumbnailerTests {
    struct Fixture: Sendable, CustomTestStringConvertible {
        let name: String
        let data: Data
        let width: Int
        let height: Int
        /// The quarters' colors once laid on white: top left, top right, bottom left, bottom right.
        let quarters: [RGB]
        var testDescription: String { name }
    }

    struct RGB: Sendable, Equatable, CustomStringConvertible {
        let red: Int, green: Int, blue: Int
        init(_ red: Int, _ green: Int, _ blue: Int) {
            self.red = red
            self.green = green
            self.blue = blue
        }
        var description: String { "(\(red), \(green), \(blue))" }

        func isClose(to other: RGB, by tolerance: Int = 24) -> Bool {
            max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue)) <= tolerance
        }
    }

    nonisolated static let red = RGB(230, 30, 30), green = RGB(30, 200, 30), blue = RGB(30, 30, 230)
    nonisolated static let white = RGB(255, 255, 255), black = RGB(0, 0, 0)

    /// `cjpeg -quality 90`: baseline, 4:2:0, 240 × 160.
    nonisolated static let baselineJPEG = fixture("""
        /9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMU
        FRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU
        FBQUFBQUFBT/wAARCACgAPADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUF
        BAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVW
        V1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi
        4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAEC
        AxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVm
        Z2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq
        8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDxqiiivyQ/0LCiiigAooooAKKKKACiiigAooooAKKKKACvaq8Vr2qvCzT7Hz/Q/hv6Tf8A
        zJ/+4/8A7hCiiivCP4bCiiigAooooAKKKKACiiigAooooAKKKKAPFaKKK+6P9yAooooAKKKKACiiigAooooAKKKKACiiigAr2qvF
        a9qrws0+x8/0P4b+k3/zJ/8AuP8A+4Qooorwj+GwooooAKKKKACiiigAooooAKKKKACiiigDxWiiivuj/cgKKKKACiiigAooooAK
        KKKACiiigAooooAK9qrxWvaq8LNPsfP9D+G/pN/8yf8A7j/+4Qooorwj+GwooooAKKKKACiiigAooooAKKKKACiiigDxWiiivuj/
        AHICiiigAooooAKKKKACiiigAooooAKKKKACvaq8Vr2qvCzT7Hz/AEP4b+k3/wAyf/uP/wC4Qooorwj+GwooooAKKKKACiiigAoo
        ooAKKKKACiiigDxWiiivuj/cgKKKKACiiigAooooAKKKKACiiigAooooAK9qrxWvaq8LNPsfP9D+G/pN/wDMn/7j/wDuEKKKK8I/
        hsKKKKACiiigAooooAKKKKACiiigAooooA+MqKKK/wBoD+kgooooAKKKKACiiigAooooAKKKKACiiigAr+huv55K/obr+efFv/mB
        /wC4n/uM9bAfa+X6hRRRX89HqhRRRQAUUUUAFFFFABRRRQAUUUUAFFFFAH88lFFFf6FnygUUUUAFFFFABRRRQAUUUUAFFFFABRRR
        QAV/Q3X88lf0N1/PPi3/AMwP/cT/ANxnrYD7Xy/UKKKK/no9UKKKKACiiigAooooAKKKKACiiigAooooA/nkooor/Qs+UCiiigAo
        oooAKKKKACiiigAooooAKKKKACv6G6/nkr+huv558W/+YH/uJ/7jPWwH2vl+oUUUV/PR6oUUUUAFFFFABRRRQAUUUUAFFFFABRRR
        QB/PJRRRX+hZ8oFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFf0N1/PJX9Ddfzz4t/8wP/AHE/9xnrYD7Xy/UKKKK/no9UKKKKACii
        igAooooAKKKKACiiigAooooA/nkooor/AELPlAooooAKKKKACiiigAooooAKKKKACiiigAr+huv55K/obr+efFv/AJgf+4n/ALjP
        WwH2vl+oUUUV/PR6oUUUUAFFFFABRRRQAUUUUAFFFFABRRRQB//Z
        """)

    /// `cjpeg -quality 90 -progressive`: 160 × 240, standing.
    nonisolated static let progressiveJPEG = fixture("""
        /9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMU
        FRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU
        FBQUFBQUFBT/wgARCADwAKADASIAAhEBAxEB/8QAGAABAQEBAQAAAAAAAAAAAAAAAAYJCAf/xAAYAQEBAQEBAAAAAAAAAAAAAAAA
        CAUHBv/aAAwDAQACEAMQAAABjB5GhQAAALUYUNgAAARQ3bkAAAAtRhQ2AAABFDduQAAAC1GFDYAAAEUN25AAAALUYUNgAAARQ3bk
        AAAAtRhQ2AAABFDduQAAAC1GFDYAAAEUN25AAAALUYUNgAAARSOd3pexRwsUcLFHCxRw9mdTuW8X5YdTjlh1OOWHU45YdTjPIVXt
        AAAAaGietYAAADPIULkgAAAaGietYAAADPIULkgAAAaGietYAAADPIULkgAAAaGietYAAADPIULkgAAAaGietYAAADPIULkgAAAa
        GietYAAADPIULkgAAAaGietYAAAD/8QAFBABAAAAAAAAAAAAAAAAAAAAkP/aAAgBAQABBQIWP//EABwRAAEEAwEAAAAAAAAAAAAA
        ABYAY2ShouHiYP/aAAgBAwEBPwHwxpHy5RpHy5RpHy5RpHy5RpHy5Q+7W0Pu1tD7tbQ+7W0Pu1vw/wD/xAAdEQAABgMBAAAAAAAA
        AAAAAAAAFRZjZKGi4eJg/9oACAECAQE/AfDIOTh0EHJw6CDk4dBBycOgg5OHQJnK2CZytgmcrYJnK2CZyt+H/8QAFBABAAAAAAAA
        AAAAAAAAAAAAkP/aAAgBAQAGPwIWP//EABQQAQAAAAAAAAAAAAAAAAAAAJD/2gAIAQEAAT8hFj//2gAMAwEAAgADAAAAEP8A/wD/
        AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A
        /wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/DDDDD//AP8A/wAMMMMPzzzzwMMMMPzzzzwMMMMPzzzzwMMMMPzzzzwMMMMPzzzzwMMM
        MPzzzzwMMMMPzzzzz//EABQRAQAAAAAAAAAAAAAAAAAAAHD/2gAIAQMBAT8QFqqqozMz/8QAFBEBAAAAAAAAAAAAAAAAAAAAcP/a
        AAgBAgEBPxAW3d3YiIj/xAAUEAEAAAAAAAAAAAAAAAAAAACQ/9oACAEBAAE/EBY//9k=
        """)

    /// `cjpeg -quality 90 -grayscale`: 240 × 160, the quarters in the grays of their colors.
    nonisolated static let grayscaleJPEG = fixture("""
        /9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMU
        FRUVDA8XGBYUGBIUFRT/wAALCACgAPABAREA/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUF
        BAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVW
        V1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi
        4+Tl5ufo6erx8vP09fb3+Pn6/9oACAEBAAA/APGqKKKKKKKKKKKKKK9qoooooooooooooorxWiiiiiiiiiiiiiivaqKKKKKKKKKK
        KKKK8Voooooooooooooor2qiiiiiiiiiiiiiivFaKKKKKKKKKKKKKK9qoooooooooooooorxWiiiiiiiiiiiiiivaqKKKKKKKKKK
        KKKK8Voooooooooooooor2qiiiiiiiiiiiiiivFaKKKKKKKKKKKKKK9qoooooooooooooorxWiiiiiiiiiiiiiivaqKKKKKKKKKK
        KKKK8Voooooooooooooor2qiiiiiiiiiiiiiivFaKKKKKKKKKKKKKK9qoooooooooooooor4yoooooooooooooor+huiiiiiiiii
        iiiiiv55KKKKKKKKKKKKKKK/oboooooooooooooor+eSiiiiiiiiiiiiiiv6G6KKKKKKKKKKKKKK/nkoooooooooooooor+huiii
        iiiiiiiiiiiv55KKKKKKKKKKKKKKK/oboooooooooooooor+eSiiiiiiiiiiiiiiv6G6KKKKKKKKKKKKKK/nkoooooooooooooor
        +huiiiiiiiiiiiiiiv55KKKKKKKKKKKKKKK/oboooooooooooooor+eSiiiiiiiiiiiiiiv6G6KKKKKKKKKKKKKK/nkooooooooo
        ooooor+huiiiiiiiiiiiiiiv/9k=
        """)

    /// ImageIO's JPEG of a CMYK image, 240 × 160, inks red, green, blue and black, stored inverted with an Adobe
    /// marker.
    nonisolated static let cmykJPEG = fixture("""
        /9j/4AAQSkZJRgABAQAASABIAAD/4QBARXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAA8KADAAQA
        AAABAAAAoAAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/+4ADkFk
        b2JlAGQAAAAAAP/AABQIAKAA8AQBEQACEQEDEQEEEQH/xAAfAAABBQEBAQEBAQAAAAAAAAAAAQIDBAUGBwgJCgv/xAC1EAACAQMD
        AgQDBQUEBAAAAX0BAgMABBEFEiExQQYTUWEHInEUMoGRoQgjQrHBFVLR8CQzYnKCCQoWFxgZGiUmJygpKjQ1Njc4OTpDREVGR0hJ
        SlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX
        2Nna4eLj5OXm5+jp6vHy8/T19vf4+fr/xAAfAQADAQEBAQEBAQEBAAAAAAAAAQIDBAUGBwgJCgv/xAC1EQACAQIEBAMEBwUEBAAB
        AncAAQIDEQQFITEGEkFRB2FxEyIygQgUQpGhscEJIzNS8BVictEKFiQ04SXxFxgZGiYnKCkqNTY3ODk6Q0RFRkdISUpTVFVWV1hZ
        WmNkZWZnaGlqc3R1dnd4eXqCg4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2dri4+Tl
        5ufo6ery8/T19vf4+fr/2wBDAAEBAQEBAQIBAQIDAgICAwUDAwMDBQYFBQUFBQYHBgYGBgYGBwcHBwcHBwcICAgICAgKCgoKCgsL
        CwsLCwsLCwv/2wBDAQICAgMDAwUDAwUMCAYIDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM
        DAz/3QAEAB7/2gAOBAEAAhEDEQQRAD8A/v4r/n/P+f8AP9/AoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAD/AHr/v8AAo
        AAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAD//Q/v4r/n/P+f8AP9/AoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAo
        AD/AHr/v8AAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAD//R/v4r/n/P+f8AP9/AoAAoAAoAAoAAoAAoAAoAAoAAoAAo
        AAoAAoAAoAAoAD/AHr/v8AAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAD//S/v4r/n/P+f8AP9/AoAAoAAoAAoAAoAAo
        AAoAAoAAoAAoAAoAAoAAoAAoAD/AHr/v8AAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAD//T/v4r/n/P+f8AP9/AoAAo
        AAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAD/AHr/v8AAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAD//U/v4r/n/P
        +f8AP9/AoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAD/AHr/v8AAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoA
        D//V/v4r/n/P+f8AP9/AoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAD/AHr/v8AAoAAoAAoAAoAAoAAoAAoAAoAAoAAoA
        AoAAoAAoAAoAD//W/v4r/n/P+f8AP9/AoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAD/AHr/v8AAoAAoAAoAAoAAoAAoA
        AoAAoAAoAAoAAoAAoAAoAAoAD//X/v4r/n/P+f8AP9/AoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAD/AHr/v8AAoAAoA
        AoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAD//Q/v4r/n/P+f8AP9/AoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAD/A
        Hr/v8AAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAAoAD//R/wA/+v8An/P9/D/fwKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAK
        AAKAAKAAKAA/3+K/7/AP+AMKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAA//S/wA/+v8An/P9/D/fwKAAKAAKAAKAAKAA
        KAAKAAKAAKAAKAAKAAKAAKAAKAA/3+K/7/AP+AMKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAA//T/wA/+v8An/P9/D/f
        wKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAA/3+K/7/AP+AMKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAA//U
        /wA/+v8An/P9/D/fwKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAA/3+K/7/AP+AMKAAKAAKAAKAAKAAKAAKAAKAAKAAKA
        AKAAKAAKAAKAA//V/wA/+v8An/P9/D/fwKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAA/3+K/7/AP+AMKAAKAAKAAKAAK
        AAKAAKAAKAAKAAKAAKAAKAAKAAKAA//W/wA/+v8An/P9/D/fwKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAA/3+K/7/AP
        +AMKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAA//X/wA/+v8An/P9/D/fwKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKA
        AKAAKAA/3+K/7/AP+AMKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAA//Q/wA/+v8An/P9/D/fwKAAKAAKAAKAAKAAKAAK
        AAKAAKAAKAAKAAKAAKAAKAA/3+K/7/AP+AMKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAA//R/wA/+v8An/P9/D/fwKAA
        KAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAA/3+K/7/AP+AMKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAA//S/wA/
        +v8An/P9/D/fwKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAA/3+K/7/AP+AMKAAKAAKAAKAAKAAKAAKAAKAAKAAKAAKAA
        KAAKAAKAA//Z
        """)

    /// RGBA, 8 bits, 120 × 80: the top left quarter transparent, the bottom right one black.
    nonisolated static let alphaPNG = fixture("""
        iVBORw0KGgoAAAANSUhEUgAAAHgAAABQCAYAAADSm7GJAAAA0ElEQVR42u3RAQ0AMAgEMZS8fylTMhtsNgi95BS0alk56U0XYMCA
        AQMGDBgwYMCAAQMGDBgwYMCAAQMGDBgwYMCAAQMGDBgwYMCAAQMGDBgwYMCAAQMGDBgwYMCAAQMGDBgwYMCAAQMGDBgwYMCAAQMG
        DBjwUODk9qa/8a4BAwYMGDBgwIABAwYMGDBgwIABAwYMGDBgwIABAwYMGDBgwIABAwYMGDBgwIABAwYMGDBgwIABAwYMGDBgwIAB
        AwYMGDBgwIABAwYMGDBgwIBn/gAHIyrxOPjJNAAAAABJRU5ErkJggg==
        """)

    /// A palette of 2 bits, 120 × 80, whose first color (top left) is transparent; the bottom right quarter is red.
    nonisolated static let palettePNG = fixture("""
        iVBORw0KGgoAAAANSUhEUgAAAHgAAABQAgMAAACv9VkaAAAADFBMVEX///8eyB4eHubmHh6UFdr9AAAAAXRSTlMAQObYZgAAAChJ
        REFUeNrtybENAAAIw7A+yZM8CXNOqBSvTmgotm3bdb10ZNu2XdcPG++rjZ9F0zEAAAAASUVORK5CYII=
        """)

    /// RGB, 16 bits and no gamma chunk, 120 × 80: the bottom right quarter is mid gray (0x8080).
    nonisolated static let deepPNG = fixture("""
        iVBORw0KGgoAAAANSUhEUgAAAHgAAABQEAIAAAANafqdAAABD0lEQVR42u3SMQEAMAjAsClB6+ShBB2bCXhIjyrIqYqfdz8i0/t/
        UAMaaAcaaKAdaKAdaKCBdqCBdqCBBtqBBtqBBhpoBxpoBxpooB1ooB1ooIF2oIF2oIEG2oEG2oEGGmgHGmgHGmigHWigHWiggXag
        gXaggQbagQbagQYaaAcaaAcaaKAdaKAdaKCBdqCBdtSABtqBBno5aNxmfjUS0EAD7UADDbSABlpAAw20Aw20Aw000AIaaAENNNAO
        NNAONNBAC2igBTTQQDvQQDvQQAMtoIEW0EAD7UAD7UADDbSABlpAAw20Aw20Aw000AIaaAENNNAONNAONNBAC2igBTTQQDvQQDvQ
        QAMtoIFe3gPnCKs4pcu1gQAAAABJRU5ErkJggg==
        """)

    /// `cwebp -q 85`: lossy, 120 × 80.
    nonisolated static let lossyWebP = fixture("""
        UklGRq4AAABXRUJQVlA4IKIAAACwCACdASp4AFAAPlEkj0UjoiEVNAA4BQSxgEqB/IPwA03P4AfrdQgFd/7oB/VQIXjX9POtmZmK
        DxD1d4oaEAAr+RwKIB8X7l3dwliXYAAA/u/9uuLlegWTZhea99o/+AAFCp/YO1n28SVh91PT85fA/Eo2FxijduwdAXf4fdiZf/9f
        bQ8FrvqdlkCh/798XX9Cjoy/tvQ0C7/gozGuG4keAAA=
        """)

    /// `cwebp -lossless` of the RGBA PNG: transparent top left, black bottom right.
    nonisolated static let losslessWebP = fixture("""
        UklGRj4AAABXRUJQVlA4TDEAAAAvd8ATEB8gkE1Okv8iHg+BQBLW/jBzzH8AdouBSIDEk570pJEDpIj+T0DoqZGMlhoJAA==
        """)

    nonisolated static let fixtures: [Fixture] = [
        Fixture(name: "baseline JPEG", data: baselineJPEG, width: 240, height: 160, quarters: [red, green, blue, white]),
        Fixture(name: "progressive JPEG", data: progressiveJPEG, width: 160, height: 240, quarters: [red, green, blue, white]),
        Fixture(name: "grayscale JPEG", data: grayscaleJPEG, width: 240, height: 160,
                quarters: [RGB(90, 90, 90), RGB(130, 130, 130), RGB(53, 53, 53), white]),
        Fixture(name: "CMYK JPEG", data: cmykJPEG, width: 240, height: 160,
                quarters: [RGB(255, 0, 0), RGB(0, 255, 0), RGB(0, 0, 255), black]),
        Fixture(name: "RGBA PNG", data: alphaPNG, width: 120, height: 80, quarters: [white, green, blue, black]),
        Fixture(name: "palette PNG", data: palettePNG, width: 120, height: 80, quarters: [white, green, blue, red]),
        Fixture(name: "16-bit PNG", data: deepPNG, width: 120, height: 80, quarters: [red, green, blue, RGB(128, 128, 128)]),
        Fixture(name: "lossy WebP", data: lossyWebP, width: 120, height: 80, quarters: [red, green, blue, white]),
        Fixture(name: "lossless WebP", data: losslessWebP, width: 120, height: 80, quarters: [white, green, blue, black]),
    ]

    nonisolated private static func fixture(_ base64: String) -> Data {
        Data(base64Encoded: base64, options: .ignoreUnknownCharacters)!
    }

    /// Every format the platform reads comes out a JPEG whose longest side is 48 pixels.
    @Test(arguments: fixtures)
    func shrinksImagesIntoJPEG(_ fixture: Fixture) throws {
        #if (canImport(CoreGraphics) && canImport(ImageIO)) || (canImport(CTurboJPEG) && canImport(CPNG) && canImport(CWebP))
        let thumbnail = try #require(Thumbnailer.jpeg(fixture.data, maxPixelSize: 48))
        let frame = try #require(Self.frame(of: thumbnail))
        #expect(frame.width == (fixture.width > fixture.height ? 48 : 32))
        #expect(frame.height == (fixture.width > fixture.height ? 32 : 48))
        #endif
    }

    #if canImport(CoreGraphics) && canImport(ImageIO)
    /// ImageIO would lay transparency on black; the Mac's thumbnails lay it on white, like Linux's.
    @Test func laysTransparencyOnWhiteOnTheMac() throws {
        let thumbnail = try #require(Thumbnailer.jpeg(Self.alphaPNG, maxPixelSize: 48))
        let image = try #require(Self.pixels(of: thumbnail))
        Self.expectQuarters(of: image, [Self.white, Self.green, Self.blue, Self.black])
    }
    #endif

    /// An image smaller than the size asked for keeps its size.
    @Test func neverEnlarges() throws {
        #if (canImport(CoreGraphics) && canImport(ImageIO)) || (canImport(CTurboJPEG) && canImport(CPNG) && canImport(CWebP))
        let jpeg = try #require(Thumbnailer.jpeg(Self.baselineJPEG, maxPixelSize: 1000))
        #expect(Self.frame(of: jpeg)?.width == 240)
        #expect(Self.frame(of: jpeg)?.height == 160)
        let png = try #require(Thumbnailer.jpeg(Self.alphaPNG, maxPixelSize: 1000))
        #expect(Self.frame(of: png)?.width == 120)
        #expect(Self.frame(of: png)?.height == 80)
        #endif
    }

    /// EXIF orientation 6 (a camera held upright) turns the image a quarter clockwise.
    @Test func turnsJPEGsUpright() throws {
        #if (canImport(CoreGraphics) && canImport(ImageIO)) || (canImport(CTurboJPEG) && canImport(CPNG) && canImport(CWebP))
        let thumbnail = try #require(Thumbnailer.jpeg(Self.withOrientation(6, Self.baselineJPEG), maxPixelSize: 48))
        #expect(Self.frame(of: thumbnail)?.width == 32)
        #expect(Self.frame(of: thumbnail)?.height == 48)
        let image = try #require(Self.pixels(of: thumbnail))
        Self.expectQuarters(of: image, [Self.blue, Self.red, Self.white, Self.green])
        #endif
    }

    @Test func readsJPEGMarkers() {
        #expect(JPEGMarkers(Self.cmykJPEG).isAdobe)
        #expect(JPEGMarkers(Self.cmykJPEG).orientation == 1)
        #expect(!JPEGMarkers(Self.baselineJPEG).isAdobe)
        #expect(JPEGMarkers(Self.withOrientation(6, Self.baselineJPEG)).orientation == 6)
        #expect(JPEGMarkers(Self.withOrientation(8, Self.baselineJPEG, littleEndian: true)).orientation == 8)
        #expect(JPEGMarkers(Self.alphaPNG).orientation == 1)
    }

    /// Each new pixel is the mean of the old ones it covers, in part at its edges.
    @Test func averagesThePixelsEachPixelCovers() {
        let checkers = Bitmap(width: 4, height: 2, channels: 1, pixels: [0, 255, 0, 255, 255, 0, 255, 0])
        #expect(checkers.shrunk(toWidth: 2, height: 1).pixels == [128, 128])
        let ramp = Bitmap(width: 3, height: 1, channels: 1, pixels: [0, 90, 180])
        #expect(ramp.shrunk(toWidth: 2, height: 1).pixels == [30, 150])
        let colors = Bitmap(width: 2, height: 2, channels: 3, pixels: [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
        #expect(colors.shrunk(toWidth: 1, height: 1).pixels == [128, 128, 128])
        #expect(colors.fitted(in: 10).pixels == colors.pixels)
    }

    @Test func turnsBitmapsByTheirOrientation() {
        // 1 2 3
        // 4 5 6
        let image = Bitmap(width: 3, height: 2, channels: 1, pixels: [1, 2, 3, 4, 5, 6])
        let expected: [Int: [UInt8]] = [
            1: [1, 2, 3, 4, 5, 6], 2: [3, 2, 1, 6, 5, 4], 3: [6, 5, 4, 3, 2, 1], 4: [4, 5, 6, 1, 2, 3],
            5: [1, 4, 2, 5, 3, 6], 6: [4, 1, 5, 2, 6, 3], 7: [6, 3, 5, 2, 4, 1], 8: [3, 6, 2, 5, 1, 4],
        ]
        for (orientation, pixels) in expected {
            let turned = image.oriented(orientation)
            #expect(turned.pixels == pixels, "orientation \(orientation)")
            #expect(turned.width == (orientation >= 5 ? 2 : 3))
        }
    }

    @Test func laysColorsOnWhite() {
        var rgba: [UInt8] = [0, 0, 0, 128, 255, 0, 0, 255, 9, 9, 9, 0]
        Bitmap.rgb(fromRGBA: &rgba)
        #expect(rgba == [127, 127, 127, 255, 0, 0, 255, 255, 255])
        var inverted: [UInt8] = [255, 0, 0, 255, 255, 255, 255, 0]
        Bitmap.rgb(fromCMYK: &inverted, inverted: true)
        #expect(inverted == [255, 0, 0, 0, 0, 0])
        var plain: [UInt8] = [0, 255, 255, 0, 0, 0, 0, 128]
        Bitmap.rgb(fromCMYK: &plain, inverted: false)
        #expect(plain == [255, 0, 0, 127, 127, 127])
    }

    #if canImport(CTurboJPEG) && canImport(CPNG) && canImport(CWebP)
    /// libjpeg-turbo, libpng and libwebp: the size, and the colors laid on white (CMYK without color management).
    @Test(arguments: fixtures)
    func shrinksWithSystemLibraries(_ fixture: Fixture) throws {
        let thumbnail = try #require(ImageCodecs.thumbnail(fixture.data, maxPixelSize: 48))
        let image = try #require(ImageCodecs.decode(thumbnail))
        #expect(image.width == (fixture.width > fixture.height ? 48 : 32))
        #expect(image.height == (fixture.width > fixture.height ? 32 : 48))
        #expect(image.channels == (fixture.name == "grayscale JPEG" ? 1 : 3))
        Self.expectQuarters(of: image, fixture.quarters)
    }

    /// A plain JPEG small enough goes out as it is; one that is truncated still gives a thumbnail.
    @Test func keepsSmallJPEGsAndReadsDamagedOnes() throws {
        #expect(ImageCodecs.thumbnail(Self.baselineJPEG, maxPixelSize: 240) == Self.baselineJPEG)
        #expect(ImageCodecs.thumbnail(Self.cmykJPEG, maxPixelSize: 240) != Self.cmykJPEG)
        let truncated = try #require(ImageCodecs.thumbnail(Self.baselineJPEG.prefix(1000), maxPixelSize: 48))
        #expect(Self.frame(of: truncated)?.width == 48)
    }

    /// GIF and anything else these libraries don't read go out as they are.
    @Test func leavesOtherFormatsAlone() {
        let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw==")!
        #expect(ImageCodecs.thumbnail(gif, maxPixelSize: 48) == nil)
        #expect(ImageCodecs.thumbnail(Data("not an image".utf8), maxPixelSize: 48) == nil)
        #expect(ImageCodecs.thumbnail(Self.alphaPNG.prefix(60), maxPixelSize: 48) == nil)
        #expect(ImageCodecs.thumbnail(Self.lossyWebP.prefix(40), maxPixelSize: 48) == nil)
    }
    #endif

    /// Two pages: the first 200 × 400 points, cut by its crop box to the bottom 300 (red, white, then blue from the
    /// top; black above the crop box); the second 300 × 150 points, green then red from the left, turned a quarter
    /// clockwise by /Rotate.
    nonisolated static let pdf: Data = {
        let first = "0 0 0 rg 0 300 200 100 re f\n1 0 0 rg 0 200 200 100 re f\n0 0 1 rg 0 0 200 100 re f\n"
        let second = "0 1 0 rg 0 0 150 150 re f\n1 0 0 rg 150 0 150 150 re f\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 400] /CropBox [0 0 200 300] /Resources << >> /Contents 4 0 R >>",
            "<< /Length \(first.utf8.count) >>\nstream\n\(first)endstream",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 150] /Rotate 90 /Resources << >> /Contents 6 0 R >>",
            "<< /Length \(second.utf8.count) >>\nstream\n\(second)endstream",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let table = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(repeating: "0", count: 10 - String(offset).count) + "\(offset) 00000 n \n" }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
        return Data(pdf.utf8)
    }()

    /// Whether the platform draws PDFs: Core Graphics on the Mac, pdftoppm (poppler-utils) on Linux.
    nonisolated static let drawsPDFs: Bool = {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        true
        #elseif os(Linux)
        Poppler.directories.contains { FileManager.default.isExecutableFile(atPath: $0 + "/pdftoppm") }
        #else
        false
        #endif
    }()

    @Test(.enabled(if: drawsPDFs)) func drawsPDFPages() throws {
        try Self.withPDF { url in
            try Self.checkPDF(count: PDFPages.count(url: url)) { PDFPages.render(url: url, page: $0, maxPixelSize: $1) }
            let cover = try #require(PDFPages.cover(url: url, maxPixelSize: 300))
            #expect(Self.frame(of: cover)?.width == 200)
            #expect(Self.frame(of: cover)?.height == 300)
        }
    }

    /// Reader pages of a PDF: 1600 pixels on the longest side unless a width is asked for, none past the last.
    @Test(.enabled(if: drawsPDFs)) func servesPDFPages() throws {
        try Self.withPDF { url in
            let book = BookRecord(id: 1, seriesID: 1, libraryID: 1, path: url.lastPathComponent, fileName: url.lastPathComponent,
                                  format: .pdf, fileSize: Int64(Self.pdf.count), modifiedAt: nil, number: nil, extraTitle: nil,
                                  plainName: "Test", position: 0, pageCount: 2, coverPath: nil, pagePaths: [], isText: false,
                                  metadata: nil, analysisError: nil, addedAt: Date())
            let root = url.deletingLastPathComponent()
            let images = Images(cacheDirectory: root.appendingPathComponent("cache"))
            let page = try images.page(book, index: 1, maxWidth: nil, root: root)
            #expect(page.contentType == "image/jpeg")
            #expect(Self.frame(of: page.data)?.width == 800)
            #expect(Self.frame(of: page.data)?.height == 1600)
            let small = try images.page(book, index: 0, maxWidth: 600, root: root)
            #expect(Self.frame(of: small.data)?.width == 400)
            #expect(Self.frame(of: small.data)?.height == 600)
            #expect(throws: HTTPError.self) { try images.page(book, index: 2, maxWidth: nil, root: root) }
            #expect(throws: HTTPError.self) { try images.page(book, index: -1, maxWidth: nil, root: root) }
        }
    }

    #if os(macOS)
    /// Homebrew's poppler, to run the Linux code on the Mac: with COOLREADER_SYSTEM_IMAGE_LIBS=1 only.
    nonisolated static let homebrewPoppler: [String]? = {
        guard ProcessInfo.processInfo.environment["COOLREADER_SYSTEM_IMAGE_LIBS"] == "1" else { return nil }
        let directories = ["/opt/homebrew/bin", "/usr/local/bin"]
        return directories.contains { FileManager.default.isExecutableFile(atPath: $0 + "/pdftoppm") } ? directories : nil
    }()

    @Test(.enabled(if: homebrewPoppler != nil)) func drawsPDFPagesWithPoppler() throws {
        let directories = try #require(Self.homebrewPoppler)
        try Self.withPDF { url in
            try Self.checkPDF(count: Poppler.pageCount(url: url, in: directories)) {
                Poppler.render(url: url, page: $0, maxPixelSize: $1, in: directories)
            }
            let missing = url.deletingLastPathComponent().appendingPathComponent("missing.pdf")
            #expect(Poppler.pageCount(url: missing, in: directories) == nil)
            #expect(Poppler.render(url: missing, page: 0, maxPixelSize: 300, in: directories) == nil)
            #expect(Poppler.pageCount(url: url, in: ["/nonexistent"]) == nil)
        }
    }
    #endif

    /// The test PDF in a folder of its own, removed afterwards.
    private static func withPDF(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Test.pdf")
        try pdf.write(to: url)
        try body(url)
    }

    /// The page count; the crop box, the white background and /Rotate of the pages drawn; no page past the last.
    private static func checkPDF(count: Int?, render: (Int, Double) -> Data?) throws {
        #expect(count == 2)
        let first = try #require(render(0, 300))
        #expect(frame(of: first)?.width == 200)
        #expect(frame(of: first)?.height == 300)
        let firstImage = try #require(pixels(of: first))
        #expect(color(of: firstImage, x: 100, y: 50).isClose(to: RGB(255, 0, 0)))
        #expect(color(of: firstImage, x: 100, y: 150).isClose(to: white))
        #expect(color(of: firstImage, x: 100, y: 250).isClose(to: RGB(0, 0, 255)))
        let second = try #require(render(1, 300))
        #expect(frame(of: second)?.width == 150)
        #expect(frame(of: second)?.height == 300)
        let secondImage = try #require(pixels(of: second))
        #expect(color(of: secondImage, x: 75, y: 75).isClose(to: RGB(0, 255, 0)))
        #expect(color(of: secondImage, x: 75, y: 225).isClose(to: RGB(255, 0, 0)))
        #expect(render(2, 300) == nil)
    }

    /// The size and number of components in a JPEG's frame header.
    static func frame(of jpeg: Data) -> (width: Int, height: Int, components: Int)? {
        let bytes = [UInt8](jpeg)
        guard bytes.starts(with: [0xFF, 0xD8]) else { return nil }
        var offset = 2
        while offset + 10 <= bytes.count, bytes[offset] == 0xFF {
            let marker = bytes[offset + 1]
            func number(at index: Int) -> Int { Int(bytes[index]) << 8 | Int(bytes[index + 1]) }
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                return (number(at: offset + 7), number(at: offset + 5), Int(bytes[offset + 9]))
            }
            offset += 2 + number(at: offset + 2)
        }
        return nil
    }

    /// A JPEG with an EXIF segment holding only an orientation, after its JFIF segment.
    static func withOrientation(_ orientation: UInt8, _ jpeg: Data, littleEndian: Bool = false) -> Data {
        let tiff: [UInt8] = littleEndian
            ? [0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0, orientation, 0, 0, 0, 0, 0, 0, 0]
            : [0x4D, 0x4D, 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, orientation, 0, 0, 0, 0, 0, 0]
        let marker: [UInt8] = [0xFF, 0xE1, 0, UInt8(2 + 6 + tiff.count)]
        let segment = marker + Array("Exif\0\0".utf8) + tiff
        var data = jpeg
        data.insert(contentsOf: segment, at: data.startIndex + 20)
        return data
    }

    /// A JPEG's pixels in RGB (or gray), from libjpeg-turbo where it is built in, else from ImageIO.
    static func pixels(of jpeg: Data) -> Bitmap? {
        #if canImport(CTurboJPEG) && canImport(CPNG) && canImport(CWebP)
        return ImageCodecs.decode(jpeg)
        #elseif canImport(CoreGraphics) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgbx = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = rgbx.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        let rgb = rgbx.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
        return Bitmap(width: image.width, height: image.height, channels: 3, pixels: rgb)
        #else
        return nil
        #endif
    }

    static func color(of image: Bitmap, x: Int, y: Int) -> RGB {
        let offset = (y * image.width + x) * image.channels
        let samples = image.pixels[offset..<(offset + image.channels)].map { Int($0) }
        return samples.count == 1 ? RGB(samples[0], samples[0], samples[0]) : RGB(samples[0], samples[1], samples[2])
    }

    /// Checks the colors in the middle of each quarter: top left, top right, bottom left, bottom right.
    static func expectQuarters(of image: Bitmap, _ expected: [RGB], sourceLocation: SourceLocation = #_sourceLocation) {
        let quarters: [(Int, Int)] = [(1, 1), (3, 1), (1, 3), (3, 3)]
        let points = quarters.map { (x: Int, y: Int) -> (Int, Int) in (image.width * x / 4, image.height * y / 4) }
        for (point, color) in zip(points, expected) {
            let found = Self.color(of: image, x: point.0, y: point.1)
            #expect(found.isClose(to: color), "\(found) instead of \(color) at \(point)", sourceLocation: sourceLocation)
        }
    }
}
