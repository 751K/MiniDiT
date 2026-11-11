// 从本机软件原始图标生成黑白模板，保留原始字形，不重新描画 Logo。
// swift -module-cache-path /tmp/minidit-logo-cache Scripts/build-software-logo-assets.swift <C1 PNG> <LrC PNG>
// LrC 的 PNG 可由 sips -s format png <App.icns> --out <reference.png> 导出。
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("需要 Capture One 和 Lightroom Classic 的原始 PNG") }
let assets = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Apps/MiniDiT/MiniDiT/Assets.xcassets")

func load(_ path: String) throws -> NSBitmapImageRep {
    guard let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return image
}

func pixel(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
    image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
}

func clamp(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }

func save(_ name: String, source: NSBitmapImageRep, crop: CGRect,
          mask: (Int, Int) -> CGFloat) throws {
    let x0 = Int(crop.minX * CGFloat(source.pixelsWide)), y0 = Int(crop.minY * CGFloat(source.pixelsHigh))
    let width = Int(crop.width * CGFloat(source.pixelsWide)), height = Int(crop.height * CGFloat(source.pixelsHigh))
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
    let bytes = out.bitmapData!
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * out.bytesPerRow + x * 4
            bytes[offset] = 0; bytes[offset + 1] = 0; bytes[offset + 2] = 0
            bytes[offset + 3] = UInt8((clamp(mask(x + x0, y + y0)) * 255).rounded())
        }
    }
    let directory = assets.appendingPathComponent(name + ".imageset")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try out.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
    let contents: [String: Any] = ["images": [["filename": name + ".png", "idiom": "universal"]],
                                 "info": ["author": "xcode", "version": 1],
                                 "properties": ["template-rendering-intent": "template"]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("Contents.json"))
    print("Generated \(name): \(width)×\(height), from original pixels")
}

let c1 = try load(args[1])
try save("CaptureOneMonochrome", source: c1, crop: CGRect(x: 0.13, y: 0.13, width: 0.74, height: 0.74)) { x, y in
    let c = pixel(c1, x, y)
    let luminance = c.redComponent * 0.2126 + c.greenComponent * 0.7152 + c.blueComponent * 0.0722
    return (1 - luminance) * c.alphaComponent
}

let lr = try load(args[2])
let w = lr.pixelsWide, h = lr.pixelsHigh
let background = pixel(lr, w / 2, Int(CGFloat(h) * 0.13))
let lettering = pixel(lr, Int(CGFloat(w) * 0.22), Int(CGFloat(h) * 0.4))
let difference = lettering.greenComponent - background.greenComponent
guard difference > 0.2 else { fatalError("LrC 原图颜色无法区分；未生成替代字形") }
var glyph = [CGFloat](repeating: 0, count: w * h)
for y in 0..<h {
    for x in 0..<w {
        let c = pixel(lr, x, y)
        glyph[y * w + x] = clamp((c.greenComponent - background.greenComponent) / difference) * c.alphaComponent
    }
}
// 只保留原始 LrC 字标，不附加外框；沿用原画布，避免改变字形比例和显示尺寸。
try save("LightroomClassicMonochrome", source: lr, crop: CGRect(x: 0.065, y: 0.065, width: 0.87, height: 0.87)) { x, y in
    glyph[y * w + x]
}
