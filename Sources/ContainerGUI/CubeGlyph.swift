import AppKit

/// 菜单栏用的图标：与 App 图标中间那个**等距立方体**同一套几何。
///
/// 画成**模板图**（`isTemplate = true`）：系统按 alpha 通道着色，
/// 所以三个面用不同不透明度就能在菜单栏上呈现立体感，明暗模式会自动反色。
///
/// ⚠️ 沿用之前实测的结论：`MenuBarExtra` 的标签里 `.font()` / `.resizable().frame()`
/// 都不生效，能控制大小的只有「先备好 NSImage、再包成 Image」这条路 ——
/// 所以这里直接按目标点高生成位图，不依赖任何 SwiftUI 缩放修饰符。
enum CubeGlyph {

    // 等距立方体单位几何（a=1, b=tan30°, v=2b ⇒ 正方体的等距投影）
    private static let ua = 1.0
    private static let ub = 0.5773502692
    private static let uv = 1.1547005384

    /// 立方体默认高度（点）。
    ///
    /// 菜单栏高 24pt。这里给 18pt：立方体剪影比同高的方块字形**窄**（宽只有高的 0.87），
    /// 轮廓又细，所以同高度下看着比之前的箱子小一圈，需要放大一些才压得住。
    static let defaultHeight: CGFloat = 19

    /// - Parameters:
    ///   - filled: 服务运行中 → 实心三面；否则只画线框
    ///   - height: 立方体高度（点）
    static func image(filled: Bool, height: CGFloat = defaultHeight) -> NSImage {
        let unitW = 2 * ua
        let unitH = 2 * ub + uv                 // 立方体总高（单位）
        let w = height * CGFloat(unitW / unitH) // 等比推出宽度
        // 位图按 Retina 备双倍像素；但 NSBitmapImageRep 的绘图上下文用的是
        // **点**坐标（实测：rep.size = 50×50 且 pixelsWide = 100 时，画满 (0,0,50,50)
        // 正好铺满 100px）。所以下面一律用点做换算，绝不能拿像素数去算，
        // 否则图形会被放大一倍并从上方裁掉一半。
        let pw = max(1, Int((w * 2).rounded()))
        let ph = max(1, Int((height * 2).rounded()))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: w, height: height)

        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        ctx.shouldAntialias = true
        ctx.imageInterpolation = .high
        NSGraphicsContext.current = ctx

        // 单位坐标 → 点坐标
        func P(_ x: Double, _ y: Double) -> NSPoint {
            NSPoint(x: (x + ua) / unitW * Double(w),
                    y: (y + ub) / unitH * Double(height))
        }
        func polygon(_ pts: [(Double, Double)]) -> NSBezierPath {
            let p = NSBezierPath()
            p.move(to: P(pts[0].0, pts[0].1))
            for q in pts.dropFirst() { p.line(to: P(q.0, q.1)) }
            p.close()
            p.lineJoinStyle = .round
            return p
        }

        // 三个可见面。中心交汇点是 (0, uv - ub)。
        let top   = [(0.0, ub + uv), (ua, uv), (0.0, uv - ub), (-ua, uv)]
        let left  = [(-ua, uv), (0.0, uv - ub), (0.0, -ub), (-ua, 0.0)]
        let right = [(0.0, uv - ub), (ua, uv), (ua, 0.0), (0.0, -ub)]

        if filled {
            // 每个面向自身重心略微收缩，留出细缝 —— 小尺寸下三面边界才清晰
            func shrink(_ pts: [(Double, Double)], by inset: Double) -> [(Double, Double)] {
                let cx = pts.map(\.0).reduce(0, +) / Double(pts.count)
                let cy = pts.map(\.1).reduce(0, +) / Double(pts.count)
                return pts.map { p in
                    let dx = p.0 - cx, dy = p.1 - cy
                    let len = (dx * dx + dy * dy).squareRoot()
                    guard len > 0 else { return p }
                    let k = max(0, 1 - inset / len)
                    return (cx + dx * k, cy + dy * k)
                }
            }
            let seam = (0.5 / Double(w)) * unitW   // 约 0.5pt 的缝，小尺寸下三面才分得开
            // 顶面最亮、左面次之、右面最暗，做出立体感
            let faces: [([(Double, Double)], CGFloat)] = [
                (shrink(top,   by: seam), 1.00),
                (shrink(left,  by: seam), 0.70),
                (shrink(right, by: seam), 0.46),
            ]
            for (pts, alpha) in faces {
                NSColor.black.withAlphaComponent(alpha).setFill()
                polygon(pts).fill()
            }
        } else {
            // 线框：六边形外轮廓 + 交汇处的三条内棱，才是「立方体」而不是六边形
            let hull = [(0.0, ub + uv), (ua, uv), (ua, 0.0),
                        (0.0, -ub), (-ua, 0.0), (-ua, uv)]
            NSColor.black.setStroke()
            let outer = polygon(hull)
            outer.lineWidth = 1.1
            outer.stroke()

            let junction = (0.0, uv - ub)
            for end in [(0.0, -ub), (-ua, uv), (ua, uv)] {
                let p = NSBezierPath()
                p.move(to: P(junction.0, junction.1))
                p.line(to: P(end.0, end.1))
                p.lineWidth = 1.1
                p.lineCapStyle = .round
                p.stroke()
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: NSSize(width: w, height: height))
        img.addRepresentation(rep)
        img.isTemplate = true   // 必须为 true，否则深浅色菜单栏不反色
        return img
    }
}
