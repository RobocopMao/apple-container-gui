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

    /// 立方体高度（点）。
    ///
    /// 菜单栏高 24pt。这里给 19pt：立方体剪影比同高的方块字形**窄**（宽只有高的 0.87），
    /// 轮廓又细，所以同高度下看着比之前的箱子小一圈，需要放大一些才压得住。
    ///
    /// ⚠️ 实心态与空闲态**必须共用这一个尺寸**：两种状态的墨迹包围盒要完全一致
    /// （宽高差 0.00pt）。曾经因为空闲态取 18pt 而实心态 19pt，看起来就像「没容器时
    /// 图标大/小一条边」，所以这里刻意只留一个常量，不再按状态区分高度。
    static let height: CGFloat = 19

    /// 菜单栏图标的统一入口。
    /// 两种状态只有「实心/线框」的区别，尺寸严格一致（见上面 `height` 的说明）。
    static func menuBarImage(active: Bool) -> NSImage {
        image(filled: active, height: height)
    }

    /// - Parameters:
    ///   - filled: 服务运行中 → 实心三面；否则只画线框
    ///   - height: 立方体高度（点）
    static func image(filled: Bool, height: CGFloat = CubeGlyph.height) -> NSImage {
        let unitW = 2 * ua
        let unitH = 2 * ub + uv                 // 立方体总高（单位）
        let cubeW = height * CGFloat(unitW / unitH) // 立方体本身宽度（等比推出）

        // 画布左右各留 pad 点余量。
        // ⚠️ 不能把画布宽度正好取成立方体宽度：实心版的最宽处就是画布宽度，
        // 抗锯齿的半透明边缘会被裁掉，于是实心版显得比线框版窄（实测差 1pt）。
        // 留出余量后两种状态的墨迹尺寸才能一致。
        let pad: CGFloat = 0.75
        let w = cubeW + pad * 2

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

        // 单位坐标 → 点坐标（水平方向按 cubeW 缩放，并整体右移 pad 居中）
        func P(_ x: Double, _ y: Double) -> NSPoint {
            NSPoint(x: Double(pad) + (x + ua) / unitW * Double(cubeW),
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

        // 三面之间留的缝（点）。实心版每个面朝自身重心收缩这么多，
        // 线框版也要按同样距离内缩，两种状态的外廓才会一样大。
        let seamPt = 0.5

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
            // 缝宽换算到单位空间：x/y 缩放系数相同（cubeW/unitW == height/unitH），
            // 所以这里用 cubeW 换算即可（不能再用带 pad 的画布宽度 w）。
            let seam = Double(seamPt) * unitW / Double(cubeW)
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
            // 线框：六边形外轮廓 + 交汇处的三条内棱，才是「立方体」而不是六边形。
            //
            // ⚠️ 描边是**以路径为中心**向两侧各扩 lineWidth/2 的。直接 stroke 原六边形，
            // 线框剪影会比实心版四周各宽出 0.55pt（就是「没容器运行时图标大一条边」），
            // 而且会超出位图边界被裁掉。
            // 所以先把路径按「多边形内缩」内移 seam + lineWidth/2，让**描边的外沿**
            // 正好落在实心版的剪影上，两种状态大小才能一致。
            let lw: CGFloat = 1.1
            let insetD = seamPt + Double(lw) / 2

            // 转换到点坐标后做内缩：P() 的 x/y 缩放系数相同（cubeW/unitW == height/unitH），
            // 所以点空间里可以按各边内法线等距内移。
            let hull = [(0.0, ub + uv), (ua, uv), (ua, 0.0),
                        (0.0, -ub), (-ua, 0.0), (-ua, uv)]
            let hullPts = hull.map { P($0.0, $0.1) }
            let insetPts = insetPolygon(hullPts, by: insetD)

            NSColor.black.setStroke()

            let outer = NSBezierPath()
            outer.move(to: insetPts[0])
            for p in insetPts.dropFirst() { outer.line(to: p) }
            outer.close()
            outer.lineJoinStyle = .round
            outer.lineWidth = lw
            outer.stroke()

            // 内棱：终点用内缩后六边形的对应顶点，正好抵到外描边的内沿，不留缝也不冒头
            let junction = P(0.0, uv - ub)
            for v in [insetPts[3], insetPts[5], insetPts[1]] {
                let p = NSBezierPath()
                p.move(to: junction)
                p.line(to: v)
                p.lineWidth = lw
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

    /// 把凸多边形按每条边的内法线等距内移 `distance`（点）。
    ///
    /// 用于抵消描边向外扩张的半个线宽，让线框版的外沿与实心版剪影对齐。
    /// 顶点取相邻两条内移后直线的交点，凸多边形下这样得到的是精确的等距内缩。
    private static func insetPolygon(_ pts: [NSPoint], by distance: Double) -> [NSPoint] {
        let n = pts.count
        guard n >= 3, distance != 0 else { return pts }

        // 先求每条边内移后的直线（用法线 + 线上一点表示）
        var lines: [(point: NSPoint, dir: NSPoint)] = []
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % n]
            let ex = b.x - a.x, ey = b.y - a.y
            let len = (ex * ex + ey * ey).squareRoot()
            guard len > 0 else { continue }
            // 边的单位方向向量
            let dx = ex / len, dy = ey / len
            // 该多边形的顶点为逆时针（数学坐标系）时，(-dy, dx) 指向内侧；
            // 用多边形面积符号判定环绕方向，保证内法线朝向正确。
            var nx = -dy, ny = dx
            if signedArea(pts) < 0 { nx = -nx; ny = -ny }
            // 直线上的点：原端点沿内法线移动 distance
            let p = NSPoint(x: a.x + nx * distance, y: a.y + ny * distance)
            // ⚠️ 必须是**边的方向**参与求交，不能用法线 —— 法线方向定义的是过该点的垂线，
            // 那是另一条直线，交点会飞到很远的地方（会把图形缩得极小）。
            lines.append((p, NSPoint(x: dx, y: dy)))
        }
        guard lines.count == n else { return pts }

        // 相邻两条内移直线的交点
        var out: [NSPoint] = []
        for i in 0..<n {
            let l1 = lines[(i - 1 + n) % n], l2 = lines[i]
            // 直线 1: p1 + t*d1，直线 2: p2 + s*d2  → 解 p1 + t*d1 = p2 + s*d2
            let denom = l1.dir.x * l2.dir.y - l1.dir.y * l2.dir.x
            if abs(denom) < 1e-9 {
                out.append(l2.point)   // 近乎平行（边共线）：直接取边上一点
                continue
            }
            let dx = l2.point.x - l1.point.x, dy = l2.point.y - l1.point.y
            let t = (dx * l2.dir.y - dy * l2.dir.x) / denom
            out.append(NSPoint(x: l1.point.x + l1.dir.x * t,
                               y: l1.point.y + l1.dir.y * t))
        }
        return out
    }

    /// 多边形有向面积（判断顶点环绕方向）
    private static func signedArea(_ pts: [NSPoint]) -> Double {
        var s = 0.0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            s += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        return s / 2
    }
}
