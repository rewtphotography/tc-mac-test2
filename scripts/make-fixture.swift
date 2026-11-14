// Makes a folder of made-up "raw" files for the automated build's launch check: each is laid
// out like a Sony ARW (a TIFF whose tables point at three embedded JPEGs and the camera
// settings) around a drawn picture. No real photo is ever kept in the repository. Apple's
// decoder can't develop these, so the app shows their embedded JPEG, which is enough to see
// the window, the thumbnails and both views.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let folder = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

func jpeg(_ index: Int, width: Int, height: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let hue = CGFloat(index) / 9
    let top = NSColor(calibratedHue: hue, saturation: 0.55, brightness: 0.75, alpha: 1).cgColor
    let bottom = NSColor(calibratedHue: hue + 0.08, saturation: 0.7, brightness: 0.25, alpha: 1).cgColor
    let gradient = CGGradient(colorsSpace: space, colors: [bottom, top] as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
    let r = CGFloat(height) * 0.22
    ctx.fillEllipse(in: CGRect(x: CGFloat(width) * (0.25 + 0.06 * CGFloat(index)) - r, y: CGFloat(height) * 0.5 - r, width: 2 * r, height: 2 * r))
    let text = NSAttributedString(string: "\(index + 1)", attributes: [
        .font: NSFont.boldSystemFont(ofSize: CGFloat(height) * 0.3),
        .foregroundColor: NSColor(white: 0.1, alpha: 1),
    ])
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    text.draw(at: CGPoint(x: CGFloat(width) * 0.62, y: CGFloat(height) * 0.3))
    NSGraphicsContext.current = nil
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    CGImageDestinationFinalize(dest)
    return out as Data
}

var file = Data()
func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
func u32(_ v: Int) -> [UInt8] { (0 ..< 4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: Int) -> [UInt8] {
    u16(tag) + u16(type) + u32(count) + (type == 3 && count == 1 ? u16(value) + u16(0) : u32(value))
}

for index in 0 ..< 9 {
    let preview = jpeg(index, width: 1616, height: 1080)
    let thumb = jpeg(index, width: 160, height: 120)
    let full = jpeg(index, width: 3000, height: 2000)
    let model = Array("ILCE-7M4".utf8) + [0]
    // Fixed places for the tables and their values; the JPEGs follow from 1024.
    let previewAt = 1024, thumbAt = previewAt + preview.count, fullAt = thumbAt + thumb.count
    var bytes = [UInt8](repeating: 0, count: 1024)
    func put(_ at: Int, _ b: [UInt8]) { bytes.replaceSubrange(at ..< at + b.count, with: b) }
    put(0, [0x49, 0x49, 42, 0] + u32(8))
    // IFD0: model, orientation, the preview, the Exif table.
    put(8, u16(5) + entry(0x110, 2, model.count, 600) + entry(0x112, 3, 1, 1) + entry(0x201, 4, 1, previewAt)
        + entry(0x202, 4, 1, preview.count) + entry(0x8769, 4, 1, 300) + u32(200))
    // IFD1: the thumbnail. IFD2: the full-size JPEG.
    put(200, u16(2) + entry(0x201, 4, 1, thumbAt) + entry(0x202, 4, 1, thumb.count) + u32(250))
    put(250, u16(2) + entry(0x201, 4, 1, fullAt) + entry(0x202, 4, 1, full.count) + u32(0))
    // Exif: exposure, aperture, ISO, focal length.
    put(300, u16(4) + entry(0x829A, 5, 1, 700) + entry(0x829D, 5, 1, 708) + entry(0x8827, 3, 1, 100 * (index + 1))
        + entry(0x920A, 5, 1, 716) + u32(0))
    put(600, model)
    put(700, u32(1) + u32(125) + u32(16) + u32(10) + u32(850) + u32(10))
    file = Data(bytes) + preview + thumb + full
    try file.write(to: URL(fileURLWithPath: folder).appendingPathComponent(String(format: "FIXTURE_%04d.ARW", index + 1)))
}
print("made 9 frames in \(folder)")
