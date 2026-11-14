// Draws the app icon (a yellow star over a white picture frame, as on the Android app) at
// every size macOS wants, into an .iconset folder. Run by scripts/make-app.sh.
import AppKit

let folder = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

func png(_ pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Draw in a 1024-unit square with y running down.
    let s = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: s, y: -s)

    ctx.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 186, cornerHeight: 186, transform: nil))
    ctx.setFillColor(CGColor(srgbRed: 0.078, green: 0.078, blue: 0.086, alpha: 1))
    ctx.fillPath()

    ctx.addPath(CGPath(roundedRect: CGRect(x: 232, y: 332, width: 560, height: 372), cornerWidth: 28, cornerHeight: 28, transform: nil))
    ctx.setStrokeColor(CGColor(srgbRed: 0.957, green: 0.957, blue: 0.961, alpha: 1))
    ctx.setLineWidth(36)
    ctx.strokePath()

    let star: [(CGFloat, CGFloat)] = [(512, 348), (552, 463), (674, 465), (577, 539), (612, 656),
                                      (512, 586), (412, 656), (447, 539), (350, 465), (472, 463)]
    ctx.move(to: CGPoint(x: star[0].0, y: star[0].1))
    for p in star.dropFirst() { ctx.addLine(to: CGPoint(x: p.0, y: p.1)) }
    ctx.closePath()
    ctx.setFillColor(CGColor(srgbRed: 0.961, green: 0.773, blue: 0.259, alpha: 1))
    ctx.fillPath()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    try png(pixels).write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
}
