// Draws the Mac app's icon, books on a shelf on a warm red square, into an .iconset folder for iconutil:
//
//   swift Scripts/make-mac-icon.swift build/AppIcon.iconset
import CoreGraphics
import Foundation
import ImageIO

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

/// The macOS icon shape, a superellipse 824 points wide in the 1024-point canvas.
func iconShape() -> CGPath {
    let path = CGMutablePath()
    let radius: CGFloat = 412, exponent: CGFloat = 5
    for step in 0...360 {
        let angle = CGFloat(step) * .pi / 180
        let point = CGPoint(x: 512 + radius * copysign(pow(abs(cos(angle)), 2 / exponent), cos(angle)),
                            y: 512 + radius * copysign(pow(abs(sin(angle)), 2 / exponent), sin(angle)))
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

struct Book {
    var x: CGFloat
    var width: CGFloat
    var height: CGFloat
    var color: CGColor
    /// Radians, counterclockwise around the bottom left corner: the book leans on the one to its left.
    var tilt: CGFloat = 0
}

let shelfTop: CGFloat = 276
let left: CGFloat = 236
let tilt: CGFloat = 14 * .pi / 180
let books = [
    Book(x: left, width: 116, height: 440, color: color(1, 0.96, 0.89)),
    Book(x: left + 128, width: 92, height: 520, color: color(1, 0.84, 0.55)),
    Book(x: left + 232, width: 124, height: 400, color: color(1, 1, 1)),
    // Its left edge rests on the white book's top right corner.
    Book(x: left + 356 + 400 * tan(tilt), width: 100, height: 430, color: color(1, 0.91, 0.78), tilt: tilt),
]

/// The icon in a 1024-point canvas; `scale` is the canvas's pixels per point, which shadows don't follow by themselves.
func draw(in context: CGContext, scale: CGFloat) {
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: color(0, 0, 0, 0.3))
    context.addPath(iconShape())
    context.setFillColor(color(0.85, 0.27, 0.2))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(iconShape())
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0.96, 0.42, 0.29), color(0.78, 0.18, 0.14)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    let last = books[books.count - 1]
    let right = last.x + last.width * cos(last.tilt)
    context.addPath(CGPath(roundedRect: CGRect(x: left - 36, y: shelfTop - 26, width: right - left + 72, height: 26),
                           cornerWidth: 13, cornerHeight: 13, transform: nil))
    context.setFillColor(color(0.45, 0.07, 0.05, 0.45))
    context.fillPath()

    for book in books {
        context.saveGState()
        context.translateBy(x: book.x, y: shelfTop)
        context.rotate(by: book.tilt)
        let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: book.width, height: book.height), cornerWidth: 12, cornerHeight: 12,
                          transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 16 * scale, color: color(0.3, 0.02, 0, 0.35))
        context.addPath(path)
        context.setFillColor(book.color)
        context.fillPath()
        context.restoreGState()
        // Two bands across the spine.
        context.addPath(path)
        context.clip()
        context.setFillColor(color(0.78, 0.18, 0.14, 0.6))
        for fraction: CGFloat in [0.12, 0.84] {
            context.fill(CGRect(x: 0, y: book.height * fraction, width: book.width, height: 16))
        }
        context.restoreGState()
    }
    context.restoreGState()
}

let sizes = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
             ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, pixels) in sizes {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    draw(in: context, scale: scale)
    let url = output.appendingPathComponent("icon_\(name).png")
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("Couldn't draw \(url.path).")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(url.path).") }
}
