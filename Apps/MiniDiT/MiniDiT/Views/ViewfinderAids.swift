import AppKit
import Observation
import SwiftUI

/// 拍摄辅助：根据取景画面在电脑上算直方图、波形、斑马纹、峰值对焦和伪色，叠加在取景上，不改相机设置。
/// 算的是相机传来的取景画面（8 位 JPEG），百分比按 0–255 换算；拍 Log 时得到的是 Log 画面本身的亮度。
struct ViewfinderAidOptions: Equatable, Sendable {
    var histogram = false
    var waveform = false
    var zebra = false
    var peaking = false
    var falseColor = false
    var zebraMode: ZebraMode = .lowerLimit
    /// 下限模式的阈值（%）：亮度不低于它的地方画斜纹。
    var zebraLevel = 95
    /// 范围模式：亮度在 中心 ± 宽度（%）之内的地方画斜纹，用来对准肤色、中灰等某一档亮度。
    var zebraCenter = 70
    var zebraRange = 10
    var peakingColor: PeakingColor = .red
    var peakingLevel: PeakingLevel = .mid
    var falseColorMode: FalseColorMode = .stops
    var histogramMode: HistogramMode = .luma
    var waveformMode: WaveformMode = .luma
    /// 取景画面是 S-Log3（Log 拍摄打开、监看 LUT 关闭）：按档位时先按 S-Log3 曲线换算。
    var logInput = false

    var anyOn: Bool { histogram || waveform || zebra || peaking || falseColor }

    enum PeakingColor: String, CaseIterable, Sendable {
        case red, yellow, white, blue
        var title: String { ["red": "红色", "yellow": "黄色", "white": "白色", "blue": "蓝色"][rawValue]! }
        var rgb: (UInt8, UInt8, UInt8) {
            switch self {
            case .red: (255, 40, 40)
            case .yellow: (255, 225, 0)
            case .white: (255, 255, 255)
            case .blue: (40, 140, 255)
            }
        }
    }

    enum PeakingLevel: Int, CaseIterable, Sendable {
        case high = 1, mid, low
        var title: String { ["高", "中", "低"][rawValue - 1] }
        /// 标出画面里最锐利的这部分边缘（比例）：只用固定门限时，亮场景里所有高反差边缘都会被标出。
        var fraction: Double { [0.08, 0.04, 0.02][rawValue - 1] }
        /// Sobel 梯度（|gx| + |gy|，0–2040）的下限：整体失焦时梯度都低，不至于硬标出一片。
        var floor: Int { [60, 70, 90][rawValue - 1] }
    }

    enum ZebraMode: String, CaseIterable, Sendable {
        case lowerLimit, range
    }

    /// 斑马纹覆盖的 8 位亮度区间（含两端）。
    var zebraBounds: ClosedRange<Int> {
        func code(_ pct: Int) -> Int { min(255, max(0, (pct * 255 + 50) / 100)) }
        switch zebraMode {
        case .lowerLimit: return code(zebraLevel)...255
        case .range: return code(zebraCenter - zebraRange)...code(zebraCenter + zebraRange)
        }
    }

    /// 给按钮提示用的说明。
    var zebraText: String {
        zebraMode == .lowerLimit ? "\(zebraLevel)% 以上" : "\(zebraCenter)% ±\(zebraRange)%"
    }

    enum HistogramMode: String, CaseIterable, Sendable {
        case luma, rgb
        var title: String { self == .luma ? "亮度" : "RGB（红绿蓝叠加）" }
    }

    enum WaveformMode: String, CaseIterable, Sendable {
        case luma, rgb, parade
        var title: String { ["luma": "亮度", "rgb": "RGB 叠加", "parade": "RGB 分量（红绿蓝并排）"][rawValue]! }
    }

    enum FalseColorMode: String, CaseIterable, Sendable {
        case stops, percent
        var title: String { self == .stops ? "按档位（相对 18% 中灰）" : "按亮度百分比" }
    }
}

/// 一帧的分析结果。图像和取景画面同比例，叠加时直接铺满取景画面。
struct ViewfinderAidResult: Sendable {
    /// 直方图，每个通道 256 档，已归一到 0–1：亮度模式 1 个通道，RGB 模式依次是红、绿、蓝。
    var histogram: [[Float]]?
    var waveform: CGImage?
    /// 生成波形图时用的模式（分量模式要画分隔线）。
    var waveformMode: ViewfinderAidOptions.WaveformMode = .luma
    /// 斑马纹和峰值对焦合在一张透明图上。
    var overlay: CGImage?
    var falseColor: CGImage?
}

enum ViewfinderAnalysis {
    /// 分析用的最大宽度：取景画面一般 1024 宽，缩到 640 已足够看，且每帧计算量小。
    static let maxWidth = 640

    static func analyze(_ image: CGImage, _ o: ViewfinderAidOptions) -> ViewfinderAidResult {
        let scale = min(1, Double(maxWidth) / Double(image.width))
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let rgba = draw(image, width: w, height: h) else { return ViewfinderAidResult() }
        let n = w * h
        // Rec.709 亮度（整数近似）。
        var luma = [UInt8](repeating: 0, count: n)
        rgba.withUnsafeBufferPointer { p in
            luma.withUnsafeMutableBufferPointer { l in
                for i in 0..<n {
                    let r = Int(p[i * 4]), g = Int(p[i * 4 + 1]), b = Int(p[i * 4 + 2])
                    l[i] = UInt8((54 * r + 183 * g + 19 * b) >> 8)
                }
            }
        }
        var out = ViewfinderAidResult()
        if o.histogram {
            out.histogram = o.histogramMode == .luma
                ? histogram([luma], stride: 1)
                : histogram([rgba], stride: 4, channels: [0, 1, 2])
        }
        if o.waveform {
            out.waveform = waveform(rgba: rgba, luma: luma, width: w, height: h, mode: o.waveformMode)
            out.waveformMode = o.waveformMode
        }
        if o.zebra || o.peaking { out.overlay = overlay(luma, width: w, height: h, o) }
        if o.falseColor { out.falseColor = falseColor(luma, width: w, height: h, o) }
        return out
    }

    // MARK: 直方图

    /// 每个通道各数一遍；用平方根压缩，所有通道按同一个峰值（中间各档里最大的）归一，
    /// 免得纯黑 / 纯白一档把其余压扁，也让红绿蓝之间的高低可比。
    static func histogram(_ sources: [[UInt8]], stride: Int, channels: [Int] = [0]) -> [[Float]] {
        let src = sources[0]
        var all: [[Int]] = []
        for ch in channels {
            var bins = [Int](repeating: 0, count: 256)
            src.withUnsafeBufferPointer { p in
                var i = ch
                while i < p.count { bins[Int(p[i])] += 1; i += stride }
            }
            all.append(bins)
        }
        let roots = all.map { $0.map { Float($0).squareRoot() } }
        let peak = max(1, roots.map { $0[2..<254].max() ?? 0 }.max() ?? 1)
        return roots.map { $0.map { min(1, $0 / peak) } }
    }

    // MARK: 波形图

    /// 横轴对应画面的列，纵轴是亮度（上 100%，下 0%），越亮表示该亮度的像素越多。
    /// - 亮度：一条绿色波形。
    /// - RGB 叠加：红绿蓝画在同一块上，三色重合处变白。
    /// - RGB 分量：红、绿、蓝各占三分之一宽度并排。
    static func waveform(rgba: [UInt8], luma: [UInt8], width w: Int, height h: Int,
                         mode: ViewfinderAidOptions.WaveformMode) -> CGImage? {
        let rows = 128
        let cols = mode == .parade ? min(w, 200) : min(w, 320)
        let gap = 4
        let total = mode == .parade ? cols * 3 + gap * 2 : cols
        // 每个通道一组计数。
        func count(_ values: UnsafeBufferPointer<UInt8>, stride: Int, offset: Int) -> [Int] {
            var counts = [Int](repeating: 0, count: cols * rows)
            for y in 0..<h {
                for x in 0..<w {
                    let c = x * cols / w
                    let r = rows - 1 - Int(values[(y * w + x) * stride + offset]) * (rows - 1) / 255
                    counts[r * cols + c] += 1
                }
            }
            return counts
        }
        let channels: [[Int]] = mode == .luma
            ? [luma.withUnsafeBufferPointer { count($0, stride: 1, offset: 0) }]
            : (0..<3).map { ch in rgba.withUnsafeBufferPointer { count($0, stride: 4, offset: ch) } }
        // 每列的像素数相同，按每列平均每格的数目归一。
        let perCell = Float(h * w / cols) / Float(rows)
        func level(_ n: Int) -> Float { n > 0 ? min(1, (Float(n) / perCell).squareRoot() * 0.35 + 0.12) : 0 }
        var px = [UInt8](repeating: 0, count: total * rows * 4)
        func put(_ x: Int, _ y: Int, _ r: Float, _ g: Float, _ b: Float) {
            let i = (y * total + x) * 4
            let a = max(r, g, b)
            px[i] = UInt8(r * 255); px[i + 1] = UInt8(g * 255); px[i + 2] = UInt8(b * 255); px[i + 3] = UInt8(a * 255)
        }
        for y in 0..<rows {
            for x in 0..<cols {
                let i = y * cols + x
                switch mode {
                case .luma:
                    let a = level(channels[0][i])
                    if a > 0 { put(x, y, a * 0.67, a, a * 0.67) }
                case .rgb:
                    let r = level(channels[0][i]), g = level(channels[1][i]), b = level(channels[2][i])
                    if r + g + b > 0 { put(x, y, r, g, b) }
                case .parade:
                    let r = level(channels[0][i]), g = level(channels[1][i]), b = level(channels[2][i])
                    // 单色看着偏暗，带一点白让细节更清楚。
                    if r > 0 { put(x, y, r, r * 0.25, r * 0.25) }
                    if g > 0 { put(x + cols + gap, y, g * 0.25, g, g * 0.25) }
                    if b > 0 { put(x + (cols + gap) * 2, y, b * 0.3, b * 0.45, b) }
                }
            }
        }
        return makeImage(px, width: total, height: rows)
    }

    // MARK: 斑马纹 + 峰值对焦

    static func overlay(_ luma: [UInt8], width w: Int, height h: Int, _ o: ViewfinderAidOptions) -> CGImage? {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        // 不开斑马纹时用一个取不到的区间。
        let zebraBounds = o.zebra ? o.zebraBounds : 256...256
        // 斜纹周期随画面宽度变，放大到窗口后粗细差不多。
        let period = max(6, w / 80)
        let (pr, pg, pb) = o.peakingColor.rgb
        var grad = [UInt16](repeating: 0, count: o.peaking ? w * h : 0)
        var threshold = Int.max
        if o.peaking, w > 2, h > 2 {
            var counts = [Int](repeating: 0, count: 2041)
            luma.withUnsafeBufferPointer { l in
                grad.withUnsafeMutableBufferPointer { gr in
                    for y in 1..<(h - 1) {
                        for x in 1..<(w - 1) {
                            let i = y * w + x
                            let a = Int(l[i - w - 1]), b = Int(l[i - w]), c = Int(l[i - w + 1])
                            let d = Int(l[i - 1]), f = Int(l[i + 1])
                            let g = Int(l[i + w - 1]), hh = Int(l[i + w]), k = Int(l[i + w + 1])
                            let m = abs((c + 2 * f + k) - (a + 2 * d + g)) + abs((g + 2 * hh + k) - (a + 2 * b + c))
                            gr[i] = UInt16(m)
                            counts[m] += 1
                        }
                    }
                }
            }
            // 从高往低累计，找到占画面 fraction 的那个梯度值。
            let target = Int(Double(w * h) * o.peakingLevel.fraction)
            var acc = 0, cut = 2040
            while cut > 0 { acc += counts[cut]; if acc >= target { break }; cut -= 1 }
            threshold = max(o.peakingLevel.floor, cut)
        }
        luma.withUnsafeBufferPointer { l in
            px.withUnsafeMutableBufferPointer { p in
                for y in 0..<h {
                    for x in 0..<w {
                        let i = y * w + x
                        if o.peaking {
                            if Int(grad[i]) >= threshold {
                                p[i * 4] = pr; p[i * 4 + 1] = pg; p[i * 4 + 2] = pb; p[i * 4 + 3] = 255
                                continue
                            }
                        }
                        if zebraBounds.contains(Int(l[i])) {
                            // 黑白相间的斜纹（预乘透明度）。
                            let light = ((x + y) / period) % 2 == 0
                            let v: UInt8 = light ? 200 : 0
                            p[i * 4] = v; p[i * 4 + 1] = v; p[i * 4 + 2] = v; p[i * 4 + 3] = light ? 200 : 140
                        }
                    }
                }
            }
        }
        return makeImage(px, width: w, height: h)
    }

    // MARK: 伪色

    typealias RGB = (UInt8, UInt8, UInt8)

    /// 按亮度百分比：中间调保持灰度，只给几个关键区间上色。
    static let percentScale: [(upTo: Int, rgb: RGB?, label: String)] = [
        (2, (130, 40, 170), "≤2% 死黑"),
        (10, (40, 90, 230), "2–10% 暗部"),
        (38, nil, ""),
        (48, (40, 180, 70), "38–48% 中灰"),
        (52, nil, ""),
        (58, (240, 130, 180), "52–58% 肤色"),
        (94, nil, ""),
        (99, (240, 220, 0), "94–99% 高光"),
        (100, (230, 30, 30), "100% 过曝"),
    ]

    /// 按档位：以 18% 中灰为 0 档，每档一种颜色（每档覆盖 ±0.5 档）。
    static let stopZones: [(stop: Int, rgb: RGB, label: String)] = [
        (-6, (45, 0, 70), "≤−6"),
        (-5, (100, 30, 160), "−5"),
        (-4, (50, 60, 200), "−4"),
        (-3, (30, 130, 230), "−3"),
        (-2, (30, 185, 200), "−2"),
        (-1, (85, 85, 85), "−1"),
        (0, (50, 185, 75), "0 中灰"),
        (1, (175, 175, 175), "+1"),
        (2, (240, 215, 50), "+2"),
        (3, (245, 145, 35), "+3"),
        (4, (225, 45, 35), "+4"),
        (5, (255, 255, 255), "≥+5"),
    ]

    /// 8 位取景值相对 18% 中灰的档数。
    /// - Log：α7 V 传来的 S-Log3 取景按窄范围编码（最暗处约 8/255，对应 S-Log3 黑位 95/1023），先还原 10 位码值再按 S-Log3 反算。
    /// - 其他：按 Rec.709 曲线反算（套了 LUT 或普通画面风格时的近似）。
    static func stops(_ v: Int, log: Bool) -> Double {
        let linear: Double
        if log {
            let code = 64 + Double(v) / 255 * 876
            linear = code >= 171.2102946929
                ? pow(10, (code - 420) / 261.5) * 0.19 - 0.01
                : (code - 95) * 0.01125 / (171.2102946929 - 95)
        } else {
            let e = Double(v) / 255
            linear = e < 0.081 ? e / 4.5 : pow((e + 0.099) / 1.099, 1 / 0.45)
        }
        return log2(max(linear, 1e-6) / 0.18)
    }

    static func falseColorTable(_ mode: ViewfinderAidOptions.FalseColorMode, log: Bool) -> [RGB] {
        (0..<256).map { v in
            switch mode {
            case .stops:
                let z = min(5, max(-6, Int(stops(v, log: log).rounded())))
                return stopZones[z + 6].rgb
            case .percent:
                let pct = Double(v) * 100 / 255
                // 只有 255 算过曝；254（99.6%）仍算高光。
                let band = v == 255 ? percentScale.last!
                    : percentScale.dropLast().first { pct <= Double($0.upTo) } ?? percentScale[percentScale.count - 2]
                if let c = band.rgb { return c }
                // 灰度部分压暗一点，让彩色区更醒目。
                let g = UInt8(Double(v) * 0.75)
                return (g, g, g)
            }
        }
    }

    static func falseColor(_ luma: [UInt8], width w: Int, height h: Int, _ o: ViewfinderAidOptions) -> CGImage? {
        let table = falseColorTable(o.falseColorMode, log: o.logInput)
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<luma.count {
            let c = table[Int(luma[i])]
            px[i * 4] = c.0; px[i * 4 + 1] = c.1; px[i * 4 + 2] = c.2
        }
        return makeImage(px, width: w, height: h)
    }

    // MARK: 工具

    private static func draw(_ image: CGImage, width w: Int, height h: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }

    private static func makeImage(_ px: [UInt8], width w: Int, height h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// 只保留最新一帧：上一帧还没算完时，新来的帧替换掉排队的那一帧。
@MainActor @Observable
final class ViewfinderAids {
    private(set) var result = ViewfinderAidResult()
    @ObservationIgnored private var running = false
    @ObservationIgnored private var queued: (CGImage, ViewfinderAidOptions)?

    func submit(_ image: NSImage?, _ options: ViewfinderAidOptions) {
        guard options.anyOn, let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            queued = nil
            if !running { result = ViewfinderAidResult() }
            return
        }
        queued = (cg, options)
        if !running { runNext() }
    }

    private func runNext() {
        guard let (image, options) = queued else { running = false; return }
        queued = nil
        running = true
        Task.detached(priority: .userInitiated) {
            let r = ViewfinderAnalysis.analyze(image, options)
            await MainActor.run {
                self.result = r
                self.runNext()
            }
        }
    }
}

// MARK: 显示

/// 直方图面板：亮度一个通道画白色；RGB 三个通道半透明叠加（重合处变亮）。两端被截断时在那一侧标出颜色。
struct HistogramView: View {
    let channels: [[Float]]

    var body: some View {
        Canvas { ctx, size in
            // 用纯红绿蓝（系统色不纯，三色叠起来会偏青而不是白）。
            let colors: [Color] = channels.count == 3
                ? [Color(red: 1, green: 0, blue: 0), Color(red: 0, green: 1, blue: 0), Color(red: 0, green: 0, blue: 1)]
                : [.white]
            ctx.blendMode = channels.count == 3 ? .plusLighter : .normal
            for (bins, color) in zip(channels, colors) {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in bins.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(bins.count - 1)
                    p.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(v))))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                ctx.fill(p, with: .color(color.opacity(channels.count == 3 ? 0.6 : 0.75)))
            }
            ctx.blendMode = .normal
            // 截断标记：亮度用红色；RGB 用该通道的颜色，上下错开。
            for (k, (bins, color)) in zip(channels, colors).enumerated() {
                let mark = channels.count == 3 ? color : Color.red
                let seg = size.height / CGFloat(channels.count)
                let rect = { (x: CGFloat) in CGRect(x: x, y: seg * CGFloat(k), width: 2, height: seg) }
                if let first = bins.first, first >= 0.98 { ctx.fill(Path(rect(0)), with: .color(mark)) }
                if let last = bins.last, last >= 0.98 { ctx.fill(Path(rect(size.width - 2)), with: .color(mark)) }
            }
            // 刻度：横轴是亮度 0–100%，每 25% 一条虚线，数字标在顶部（和波形图的 0 / 50 / 100 对应）。
            for pct in [0, 25, 50, 75, 100] {
                let x = size.width * CGFloat(pct) / 100
                if pct > 0 && pct < 100 {
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(line, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                }
                let anchor: UnitPoint = pct == 0 ? .topLeading : pct == 100 ? .topTrailing : .top
                ctx.draw(Text("\(pct)").font(.system(size: 8).monospacedDigit()).foregroundStyle(.white.opacity(0.5)),
                         at: CGPoint(x: x, y: 0), anchor: anchor)
            }
        }
        .accessibilityLabel(channels.count == 3 ? "RGB 直方图" : "亮度直方图")
    }
}

/// 波形面板：带 0 / 50 / 100% 参考线。
struct WaveformView: View {
    let image: CGImage
    var mode: ViewfinderAidOptions.WaveformMode = .luma

    var body: some View {
        ZStack {
            Image(decorative: image, scale: 1).resizable().interpolation(.medium)
            GeometryReader { geo in
                ForEach([0, 50, 100], id: \.self) { pct in
                    let y = geo.size.height * (1 - CGFloat(pct) / 100)
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y)) }
                        .stroke(.white.opacity(0.25), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    Text("\(pct)").font(.system(size: 8).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                        .position(x: 9, y: min(max(y, 6), geo.size.height - 6))
                }
            }
        }
        .accessibilityLabel(mode == .luma ? "亮度波形图" : mode == .rgb ? "RGB 波形图" : "RGB 分量图")
    }
}

/// 伪色图例。
struct FalseColorLegend: View {
    let mode: ViewfinderAidOptions.FalseColorMode
    let log: Bool

    var body: some View {
        HStack(spacing: 8) {
            if mode == .stops {
                Text(log ? "S-Log3" : "709").foregroundStyle(.white.opacity(0.6))
                ForEach(ViewfinderAnalysis.stopZones, id: \.stop) { chip($0.rgb, $0.label) }
            } else {
                ForEach(ViewfinderAnalysis.percentScale.filter { $0.rgb != nil }, id: \.upTo) { chip($0.rgb!, $0.label) }
            }
        }
        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.6), in: Capsule())
        .help(mode == .stops
              ? (log ? "按 S-Log3 曲线换算（Log 拍摄、监看 LUT 关闭）" : "按 Rec.709 曲线近似换算；套了 LUT 时看的是 LUT 之后的画面")
              : "按取景画面的亮度百分比")
    }

    private func chip(_ c: ViewfinderAnalysis.RGB, _ label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(red: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255))
                .frame(width: 9, height: 9)
            Text(label)
        }
    }
}
