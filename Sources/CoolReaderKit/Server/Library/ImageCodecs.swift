import Foundation
#if canImport(CTurboJPEG) && canImport(CPNG) && canImport(CWebP)
import CPNG
import CTurboJPEG
import CWebP
#endif

/// An 8-bit image in memory, rows from the top: gray (one channel) or RGB (three). Linux's codecs fill it (below);
/// shrinking and turning it are plain Swift.
nonisolated struct Bitmap: Sendable {
    var width: Int
    var height: Int
    var channels: Int
    var pixels: [UInt8]

    /// `width` × `height` fitted in `maxPixelSize` on its longest side, never enlarged.
    static func fittedSize(width: Int, height: Int, maxPixelSize: Double) -> (width: Int, height: Int) {
        let scale = min(1, maxPixelSize / Double(max(width, height)))
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// The image shrunk to fit in `maxPixelSize` on its longest side; as it is when it fits already or without one.
    func fitted(in maxPixelSize: Double?) -> Bitmap {
        guard let maxPixelSize else { return self }
        let size = Self.fittedSize(width: width, height: height, maxPixelSize: maxPixelSize)
        return shrunk(toWidth: size.width, height: size.height)
    }

    /// The image scaled down to `newWidth` × `newHeight`: each new pixel is the mean of the pixels it covers, those
    /// on its edges weighted by the part they cover. Rows are shrunk across one at a time, then added up.
    func shrunk(toWidth newWidth: Int, height newHeight: Int) -> Bitmap {
        guard newWidth > 0, newHeight > 0, newWidth <= width, newHeight <= height,
              newWidth < width || newHeight < height else { return self }
        let across = Coverage(from: width, to: newWidth), down = Coverage(from: height, to: newHeight)
        let width = width, channels = channels, rowLength = newWidth * channels
        var line = [Float](repeating: 0, count: rowLength), sum = line
        var lineRow = -1
        var output = [UInt8](repeating: 0, count: rowLength * newHeight)
        pixels.withUnsafeBufferPointer { source in
            for y in 0..<newHeight {
                for index in 0..<rowLength { sum[index] = 0 }
                for part in 0..<down.count[y] {
                    let row = down.first[y] + part, rowWeight = down.weights[y * down.stride + part]
                    if row != lineRow {
                        lineRow = row
                        let rowStart = row * width * channels
                        for x in 0..<newWidth {
                            let firstColumn = across.first[x], weights = x * across.stride
                            for channel in 0..<channels {
                                var value: Float = 0
                                for column in 0..<across.count[x] {
                                    value += across.weights[weights + column]
                                        * Float(source[rowStart + (firstColumn + column) * channels + channel])
                                }
                                line[x * channels + channel] = value
                            }
                        }
                    }
                    for index in 0..<rowLength { sum[index] += rowWeight * line[index] }
                }
                let outputStart = y * rowLength
                for index in 0..<rowLength { output[outputStart + index] = UInt8(min(255, sum[index] + 0.5)) }
            }
        }
        return Bitmap(width: newWidth, height: newHeight, channels: channels, pixels: output)
    }

    /// The image turned upright from its EXIF orientation (1 to 8).
    func oriented(_ orientation: Int) -> Bitmap {
        guard (2...8).contains(orientation) else { return self }
        let swapsSides = orientation >= 5
        let newWidth = swapsSides ? height : width, newHeight = swapsSides ? width : height
        var output = [UInt8](repeating: 0, count: newWidth * newHeight * channels)
        pixels.withUnsafeBufferPointer { source in
            for y in 0..<newHeight {
                for x in 0..<newWidth {
                    let (oldX, oldY) = switch orientation {
                    case 2: (width - 1 - x, y)
                    case 3: (width - 1 - x, height - 1 - y)
                    case 4: (x, height - 1 - y)
                    case 5: (y, x)
                    case 6: (y, height - 1 - x)
                    case 7: (width - 1 - y, height - 1 - x)
                    default: (width - 1 - y, x)
                    }
                    let from = (oldY * width + oldX) * channels, to = (y * newWidth + x) * channels
                    for channel in 0..<channels { output[to + channel] = source[from + channel] }
                }
            }
        }
        return Bitmap(width: newWidth, height: newHeight, channels: channels, pixels: output)
    }

    /// CMYK samples turned into RGB in place, without color management. Adobe's JPEGs (Photoshop's, ImageIO's)
    /// store the inks inverted.
    static func rgb(fromCMYK pixels: inout [UInt8], inverted: Bool) {
        // How much light an ink lets through, from 0 to 255.
        func light(_ sample: UInt8) -> Int { inverted ? Int(sample) : 255 - Int(sample) }
        let count = pixels.count / 4
        pixels.withUnsafeMutableBufferPointer { samples in
            for pixel in 0..<count {
                let from = pixel * 4, to = pixel * 3
                let black = light(samples[from + 3])
                for channel in 0..<3 {
                    samples[to + channel] = UInt8((light(samples[from + channel]) * black + 127) / 255)
                }
            }
        }
        pixels.removeLast(count)
    }

    /// RGBA samples laid on white in place, leaving RGB.
    static func rgb(fromRGBA pixels: inout [UInt8]) {
        let count = pixels.count / 4
        pixels.withUnsafeMutableBufferPointer { samples in
            for pixel in 0..<count {
                let from = pixel * 4, to = pixel * 3
                let alpha = Int(samples[from + 3]), white = 255 * (255 - alpha)
                for channel in 0..<3 {
                    samples[to + channel] = UInt8((Int(samples[from + channel]) * alpha + white + 127) / 255)
                }
            }
        }
        pixels.removeLast(count)
    }
}

/// For each pixel along one side of a shrunk image, the old pixels it covers: the first one, how many, and their
/// weights (`stride` per pixel), which add up to 1.
nonisolated private struct Coverage {
    var first: [Int]
    var count: [Int]
    var weights: [Float]
    let stride: Int

    init(from size: Int, to newSize: Int) {
        let scale = Double(size) / Double(newSize)
        stride = Int(scale.rounded(.up)) + 2
        first = [Int](repeating: 0, count: newSize)
        count = first
        weights = [Float](repeating: 0, count: newSize * stride)
        var parts: [Double] = []
        for index in 0..<newSize {
            let start = Double(index) * scale, end = min(Double(index + 1) * scale, Double(size))
            var old = min(Int(start), size - 1)
            first[index] = old
            parts.removeAll(keepingCapacity: true)
            while old < size, Double(old) < end, parts.count < stride {
                parts.append(max(0, min(Double(old + 1), end) - max(Double(old), start)))
                old += 1
            }
            let total = parts.reduce(0, +)
            for (part, covered) in parts.enumerated() {
                weights[index * stride + part] = Float(total > 0 ? covered / total : 1 / Double(parts.count))
            }
            count[index] = parts.count
        }
    }
}

/// What a JPEG says before its image data: whether Adobe wrote it (CMYK inks are then stored inverted) and how its
/// EXIF orientation turns it.
nonisolated struct JPEGMarkers {
    var isAdobe = false
    var orientation = 1

    init(_ data: Data) {
        // The segments before the image data rarely add up to more than 64 KB.
        let bytes = [UInt8](data.prefix(256 << 10))
        guard bytes.starts(with: [0xFF, 0xD8]) else { return }
        var offset = 2
        while offset + 4 <= bytes.count, bytes[offset] == 0xFF {
            let marker = bytes[offset + 1]
            if marker == 0xFF {
                offset += 1
                continue
            }
            if marker == 0xDA || marker == 0xD9 { break }
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length >= 2, offset + 2 + length <= bytes.count else { break }
            let segment = bytes[(offset + 4)..<(offset + 2 + length)]
            if marker == 0xEE, segment.starts(with: "Adobe".utf8) { isAdobe = true }
            if marker == 0xE1, segment.starts(with: "Exif\0\0".utf8) {
                orientation = Self.exifOrientation(Array(segment.dropFirst(6))) ?? orientation
            }
            offset += 2 + length
        }
    }

    /// The Orientation tag (1 to 8) of the first directory of an EXIF block.
    private static func exifOrientation(_ tiff: [UInt8]) -> Int? {
        guard tiff.count >= 8, tiff[0] == tiff[1], tiff[0] == 0x49 || tiff[0] == 0x4D else { return nil }
        let isLittleEndian = tiff[0] == 0x49
        func number(at offset: Int, size: Int) -> Int? {
            guard offset >= 0, offset + size <= tiff.count else { return nil }
            return (0..<size).reduce(0) { (value: Int, index: Int) -> Int in
                value << 8 | Int(tiff[offset + (isLittleEndian ? size - 1 - index : index)])
            }
        }
        guard number(at: 2, size: 2) == 42, let directory = number(at: 4, size: 4),
              let entries = number(at: directory, size: 2) else { return nil }
        for entry in 0..<entries {
            let offset = directory + 2 + entry * 12
            guard let tag = number(at: offset, size: 2) else { return nil }
            guard tag == 0x0112 else { continue }
            guard number(at: offset + 2, size: 2) == 3, let value = number(at: offset + 8, size: 2),
                  (1...8).contains(value) else { return nil }
            return value
        }
        return nil
    }
}

#if canImport(CTurboJPEG) && canImport(CPNG) && canImport(CWebP)
/// JPEG, PNG and WebP images shrunk into JPEGs with libjpeg-turbo, libpng and libwebp, where there is no ImageIO.
/// A JPEG is decoded already scaled down (by up to 8) where libjpeg-turbo can, a PNG or a WebP whole; then each
/// pixel of the thumbnail is the mean of the pixels it covers. A call holds one decoded image at a time.
nonisolated enum ImageCodecs {
    /// Images over 100 megapixels go out as they are rather than take hundreds of megabytes to shrink.
    static let maxPixels = 100_000_000

    /// `data` as a JPEG whose longest side is at most `maxPixelSize`, never enlarged: a JPEG small enough and
    /// already upright comes back as it is. Nil for other formats (GIF, AVIF, HEIC…) and for damaged images.
    static func thumbnail(_ data: Data, maxPixelSize: Double) -> Data? {
        guard maxPixelSize >= 1 else { return nil }
        if let header = JPEGHeader(data), header.isPlain,
           Bitmap.fittedSize(width: header.width, height: header.height, maxPixelSize: maxPixelSize)
               == (header.width, header.height) {
            return data
        }
        return decode(data, maxPixelSize: maxPixelSize).flatMap { encodeJPEG($0) }
    }

    /// An image decoded upright and laid on white, in gray or RGB, shrunk to fit in `maxPixelSize` on its longest
    /// side when one is given.
    static func decode(_ data: Data, maxPixelSize: Double? = nil) -> Bitmap? {
        switch Images.contentType(of: data) {
        case "image/jpeg": decodeJPEG(data, maxPixelSize: maxPixelSize)
        case "image/png": decodePNG(data)?.fitted(in: maxPixelSize)
        case "image/webp": decodeWebP(data)?.fitted(in: maxPixelSize)
        default: nil
        }
    }

    /// The image as a JPEG, colors subsampled 4:2:0 like ImageIO's.
    static func encodeJPEG(_ image: Bitmap, quality: Int32 = 82) -> Data? {
        guard let encoder = tjInitCompress() else { return nil }
        defer { tjDestroy(encoder) }
        var jpeg: UnsafeMutablePointer<UInt8>?
        var size: UInt = 0
        defer { tjFree(jpeg) }
        let isGray = image.channels == 1
        let status = image.pixels.withUnsafeBufferPointer { pixels in
            tjCompress2(encoder, pixels.baseAddress, Int32(image.width), 0, Int32(image.height),
                        Int32(isGray ? TJPF_GRAY.rawValue : TJPF_RGB.rawValue), &jpeg, &size,
                        Int32(isGray ? TJSAMP_GRAY.rawValue : TJSAMP_420.rawValue), quality, 0)
        }
        guard status == 0, let jpeg else { return nil }
        return Data(bytes: jpeg, count: Int(size))
    }

    /// A JPEG decoded at the smallest of libjpeg-turbo's scales (1/8 to 1) that still covers the size it must fit,
    /// then shrunk to that size and turned upright.
    private static func decodeJPEG(_ data: Data, maxPixelSize: Double?) -> Bitmap? {
        guard let header = JPEGHeader(data), let decoder = tjInitDecompress() else { return nil }
        defer { tjDestroy(decoder) }
        let target: (width: Int, height: Int) = maxPixelSize.map {
            Bitmap.fittedSize(width: header.width, height: header.height, maxPixelSize: $0)
        } ?? (header.width, header.height)
        var size = (width: header.width, height: header.height)
        var count: Int32 = 0
        if let factors = tjGetScalingFactors(&count) {
            for factor in UnsafeBufferPointer(start: factors, count: Int(count)) where factor.num < factor.denom {
                let num = Int(factor.num), denom = Int(factor.denom)
                let width = (header.width * num + denom - 1) / denom, height = (header.height * num + denom - 1) / denom
                if width >= target.width, height >= target.height, width * height < size.width * size.height {
                    size = (width, height)
                }
            }
        }
        let format = header.isGray ? TJPF_GRAY : header.isCMYK ? TJPF_CMYK : TJPF_RGB
        let channels = header.isGray ? 1 : header.isCMYK ? 4 : 3
        var status: Int32 = -1
        var pixels = data.withUnsafeBytes { jpeg in
            [UInt8](unsafeUninitializedCapacity: size.width * size.height * channels) { buffer, initialized in
                status = tjDecompress2(decoder, jpeg.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt(jpeg.count),
                                       buffer.baseAddress, Int32(size.width), 0, Int32(size.height),
                                       Int32(format.rawValue), TJFLAG_LIMITSCANS)
                initialized = buffer.count
            }
        }
        // A warning (bytes after the end, a truncated file) still leaves a whole image.
        guard status == 0 || tjGetErrorCode(decoder) == Int32(TJERR_WARNING.rawValue) else { return nil }
        if header.isCMYK { Bitmap.rgb(fromCMYK: &pixels, inverted: header.markers.isAdobe) }
        return Bitmap(width: size.width, height: size.height, channels: min(channels, 3), pixels: pixels)
            .shrunk(toWidth: target.width, height: target.height)
            .oriented(header.markers.orientation)
    }

    /// A PNG of any kind (palette, gray, 16 bits, interlaced) decoded into 8-bit gray or RGB, laid on white.
    private static func decodePNG(_ data: Data) -> Bitmap? {
        data.withUnsafeBytes { png -> Bitmap? in
            var image = png_image()
            image.version = UInt32(PNG_IMAGE_VERSION)
            guard png_image_begin_read_from_memory(&image, png.baseAddress, png.count) != 0 else { return nil }
            defer { png_image_free(&image) }
            let width = Int(image.width), height = Int(image.height)
            guard width > 0, height > 0, width * height <= maxPixels else { return nil }
            let isColor = image.format & UInt32(PNG_FORMAT_FLAG_COLOR) != 0
            let channels = isColor ? 3 : 1
            image.format = isColor ? UInt32(PNG_FORMAT_RGB) : UInt32(PNG_FORMAT_GRAY)
            // 16-bit samples without a gamma chunk are sRGB, as browsers and ImageIO read them, rather than linear.
            image.flags |= UInt32(PNG_IMAGE_FLAG_16BIT_sRGB)
            var white = png_color(red: 255, green: 255, blue: 255)
            var succeeded = false
            let pixels = [UInt8](unsafeUninitializedCapacity: width * height * channels) { buffer, initialized in
                succeeded = png_image_finish_read(&image, &white, buffer.baseAddress, Int32(width * channels), nil) != 0
                initialized = succeeded ? buffer.count : 0
            }
            return succeeded ? Bitmap(width: width, height: height, channels: channels, pixels: pixels) : nil
        }
    }

    /// A still WebP, lossy or lossless, decoded into RGB laid on white. Animations are left as they are.
    private static func decodeWebP(_ data: Data) -> Bitmap? {
        data.withUnsafeBytes { webp -> Bitmap? in
            guard let bytes = webp.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var features = WebPBitstreamFeatures()
            guard WebPGetFeatures(bytes, webp.count, &features) == VP8_STATUS_OK, features.has_animation == 0 else {
                return nil
            }
            let width = Int(features.width), height = Int(features.height)
            guard width > 0, height > 0, width * height <= maxPixels else { return nil }
            let hasAlpha = features.has_alpha != 0
            let channels = hasAlpha ? 4 : 3
            var succeeded = false
            var pixels = [UInt8](unsafeUninitializedCapacity: width * height * channels) { buffer, initialized in
                let stride = Int32(width * channels)
                succeeded = hasAlpha
                    ? WebPDecodeRGBAInto(bytes, webp.count, buffer.baseAddress, buffer.count, stride) != nil
                    : WebPDecodeRGBInto(bytes, webp.count, buffer.baseAddress, buffer.count, stride) != nil
                initialized = succeeded ? buffer.count : 0
            }
            guard succeeded else { return nil }
            if hasAlpha { Bitmap.rgb(fromRGBA: &pixels) }
            return Bitmap(width: width, height: height, channels: 3, pixels: pixels)
        }
    }
}

/// A JPEG's size and colors, read by libjpeg-turbo, and its markers.
nonisolated private struct JPEGHeader {
    let width: Int
    let height: Int
    let colorspace: Int32
    let markers: JPEGMarkers

    var isGray: Bool { colorspace == Int32(TJCS_GRAY.rawValue) }
    var isCMYK: Bool { colorspace == Int32(TJCS_CMYK.rawValue) || colorspace == Int32(TJCS_YCCK.rawValue) }
    /// A JPEG that can go out as it is when it is small enough.
    var isPlain: Bool { !isCMYK && markers.orientation == 1 }

    init?(_ data: Data) {
        guard data.starts(with: [0xFF, 0xD8]), let decoder = tjInitDecompress() else { return nil }
        defer { tjDestroy(decoder) }
        var width: Int32 = 0, height: Int32 = 0, subsampling: Int32 = 0, colorspace: Int32 = 0
        let status = data.withUnsafeBytes { jpeg in
            tjDecompressHeader3(decoder, jpeg.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt(jpeg.count),
                                &width, &height, &subsampling, &colorspace)
        }
        guard status == 0 || tjGetErrorCode(decoder) == Int32(TJERR_WARNING.rawValue), width > 0, height > 0,
              Int(width) * Int(height) <= ImageCodecs.maxPixels else { return nil }
        self.width = Int(width)
        self.height = Int(height)
        self.colorspace = colorspace
        markers = JPEGMarkers(data)
    }
}
#endif
