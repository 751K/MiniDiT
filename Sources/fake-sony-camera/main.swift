import SonyRemoteKit
import CoreGraphics
import FakeSonyCamera
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 在 Mac 上模拟一台索尼相机（PTP/IP，默认端口 15740），用来在模拟器里联调 APP。
// 用法：swift run fake-sony-camera [端口]

setvbuf(stdout, nil, _IOLBF, 0)  // 输出重定向到文件时也逐行写出
let port = CommandLine.arguments.dropFirst().first.flatMap(UInt16.init) ?? 15740

final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
let counter = FrameCounter()

func renderJPEG(width: Int, height: Int, t: Double, label: String) -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let hue = (t * 0.03).truncatingRemainder(dividingBy: 1)
    func rgb(_ h: Double, _ b: Double) -> CGColor {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = 0.3 * b, q = b * (1 - 0.7 * f), u = b * (1 - 0.7 * (1 - f))
        let (r, g, bl): (Double, Double, Double) = [(b, u, p), (q, b, p), (p, b, u), (p, q, b), (u, p, b), (b, p, q)][i]
        return CGColor(red: r, green: g, blue: bl, alpha: 1)
    }
    let gradient = CGGradient(colorsSpace: cs, colors: [rgb(hue, 0.6), rgb((hue + 0.4).truncatingRemainder(dividingBy: 1), 0.2)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    // 移动的圆点，便于看出画面在刷新。
    let r = Double(height) / 8
    let x = Double(width) / 2 + cos(t) * Double(width) / 3
    let y = Double(height) / 2 + sin(t * 1.3) * Double(height) / 4
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    // 三分线
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
    for i in 1..<3 {
        ctx.move(to: CGPoint(x: width * i / 3, y: 0)); ctx.addLine(to: CGPoint(x: width * i / 3, y: height))
        ctx.move(to: CGPoint(x: 0, y: height * i / 3)); ctx.addLine(to: CGPoint(x: width, y: height * i / 3))
    }
    ctx.strokePath()
    _ = label
    let image = ctx.makeImage()!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
    CGImageDestinationFinalize(dest)
    return out as Data
}

let state = FakeSonyState()
state.liveViewProvider = {
    let n = counter.next()
    return renderJPEG(width: 640, height: 424, t: Double(n) / 15, label: "LV")
}
state.photoProvider = {
    renderJPEG(width: 3000, height: 2000, t: Date().timeIntervalSince1970, label: "PHOTO")
}
// 存储卡：每个文件按文件名生成不同的颜色，便于区分。
func seed(_ name: String) -> Double { Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 10_000 }) / 37 }
state.card = FakeCard.sample(
    photo: { renderJPEG(width: 3000, height: 2000, t: seed($0), label: $0) },
    thumb: { renderJPEG(width: 160, height: 120, t: seed($0), label: $0) },
    photosPerFolder: 30)
// 和真机一样：不切到内容传输模式就读不到存储卡。
state.requireContentsTransferMode = true
// 远程传输：卡 1 是上面那张卡，卡 2 另放几张（加 -no-remote 模拟不支持远程传输的相机）。
if !CommandLine.arguments.contains("-no-remote") {
    let card2 = FakeCard.sample(
        photo: { renderJPEG(width: 3000, height: 2000, t: seed($0) + 50, label: "卡2 " + $0) },
        thumb: { renderJPEG(width: 160, height: 120, t: seed($0) + 50, label: "卡2 " + $0) },
        photosPerFolder: 4)
    state.remoteSlots = [1: state.card!, 2: card2]
    state.advertisedOperations = [PTPOperation.getDeviceInfo, PTPOperation.openSession, SonyOperation.sdioConnect,
                                  SonyOperation.getExtDeviceInfo, SonyOperation.getCapturedDateList,
                                  SonyOperation.getContentsInfoList, SonyOperation.getContentsData,
                                  SonyOperation.getContentsCompressedData]
}

// -serial XXXX：同时开多台模拟相机时区分机身。
if let i = CommandLine.arguments.firstIndex(of: "-serial"), i + 1 < CommandLine.arguments.count {
    state.serialNumber = CommandLine.arguments[i + 1]
}

let verbose = CommandLine.arguments.contains("-v")
state.onOperation = { line in
    if verbose || !line.hasPrefix("op 0x1009 0xFFFFC002") && !line.hasPrefix("op 0x9209") { print(line) }
}

let server = try FakeCamera(port: port) { state.handle($0, $1, $2) }
let actual = try await server.start()
print("模拟索尼相机已启动：端口 \(actual)。在模拟器 APP 里连接 127.0.0.1 即可。按 Ctrl+C 退出。")
while true { try await Task.sleep(for: .seconds(3600)) }
