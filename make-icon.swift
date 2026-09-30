#!/usr/bin/env swift
//
// make-icon.swift —— 生成 Apple Container 的 App 图标
//
// 产出两套产物：
//   1. AppIcon.icns                              —— macOS 15 及更早读 CFBundleIconFile
//   2. AppIcon.icon/ (icon.json + Assets/glyph.png) —— macOS 26+ 由 actool 编成
//      Assets.car，系统据此渲染分层图标并做深色/着色适配
//
// 设计：靛蓝渐变的圆角方块 + 白色等距立方体（container = 容器/箱体）。
//
// 注意（踩过的坑）：icon.json 只写 fill-specializations，不要写顶层 fill —
// 两者并存时顶层 fill 会盖掉深色特化，深色模式会退回系统默认底色。
//
import AppKit
import Foundation

// MARK: - 常量

let canvas = 1024.0        // 画布边长（1024 为图标母版标准尺寸）
let glyphWidthRatio = 0.52 // 立方体宽度占画布比例
let bodyInsetRatio = 0.062 // .icns 里圆角方块距画布边缘的留白比例
let bodyRadiusRatio = 0.2237 // 圆角半径占方块宽度比例（贴近 macOS 超椭圆观感）

// 等距立方体的单位几何（真实 isometric：a=1, b=tan30°, v=2b 使其为正方体投影）
let a = 1.0
let b = 0.5773502692
let v = 1.1547005384

func col(_ r: Double, _ g: Double, _ bl: Double, _ al: Double = 1.0) -> NSColor {
    NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(bl), alpha: CGFloat(al))
}

// 浅色模式背景渐变（左上 → 右下）
let lightGradient = [col(0.38, 0.56, 0.97), col(0.47, 0.29, 0.89)]
// 深色特化：纯黑底（与 c2api / wb2api 一致）。
// 只调暗或只退饱和都还会残留色相，纯黑最干净、在深色桌面上对比也最强。
let darkSolidFill = col(0.0, 0.0, 0.0)

// MARK: - 绘制工具

func makeBitmap(_ size: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        fatalError("无法创建 \(size)x\(size) 位图")
    }
    return rep
}

func drawing(_ rep: NSBitmapImageRep, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    ctx.shouldAntialias = true
    NSGraphicsContext.current = ctx
    body()
    NSGraphicsContext.restoreGraphicsState()
}

/// 等距立方体的三个面（顶面最亮、左面次之、右面最暗，形成立体感）
func cubeFaces(canvasSize: CGFloat, widthRatio: CGFloat) -> [(NSBezierPath, CGFloat)] {
    let s = (canvasSize * widthRatio) / 2.0          // 单位 → 像素
    let cx = canvasSize / 2.0
    let cy = canvasSize / 2.0 - (v / 2.0) * s        // 让立方体垂直居中

    func pt(_ x: Double, _ y: Double) -> NSPoint {
        NSPoint(x: CGFloat(x) * s + cx, y: CGFloat(y) * s + cy)
    }
    func face(_ pts: [(Double, Double)]) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: pt(pts[0].0, pts[0].1))
        for q in pts.dropFirst() { p.line(to: pt(q.0, q.1)) }
        p.close()
        p.lineJoinStyle = .round
        return p
    }

    // 顶点：A 顶、B 右、C 近、D 左；带 2 为对应底边点
    let top = face([(0, b + v), (a, v), (0, v - b), (-a, v)])
    let left = face([(-a, v), (0, v - b), (0, -b), (-a, 0)])
    let right = face([(0, v - b), (a, v), (a, 0), (0, -b)])

    return [(top, 1.0), (left, 0.80), (right, 0.62)]
}

// MARK: - 产物一：.icns（完整图标，含圆角方形底）

func renderFullIcon(size: Int, gradient: [NSColor]) -> NSBitmapImageRep {
    let rep = makeBitmap(size)
    let S = CGFloat(size)

    drawing(rep) {
        let inset = S * CGFloat(bodyInsetRatio)
        let body = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
        let radius = body.width * CGFloat(bodyRadiusRatio)
        let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        // 底色渐变
        NSGradient(colors: gradient)!.draw(in: shape, angle: -55)

        // 顶部柔和高光，增加质感
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.20),
                            NSColor.white.withAlphaComponent(0.0)])!
            .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height * 0.55),
                  angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        // 立方体
        for (path, alpha) in cubeFaces(canvasSize: S, widthRatio: CGFloat(glyphWidthRatio)) {
            NSColor.white.withAlphaComponent(alpha).setFill()
            path.fill()
        }
    }
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG 编码失败: \(url.path)"])
    }
    try data.write(to: url)
}

// MARK: - 产物二：.icon（分层图标，供 actool 编译）

func renderGlyph(size: Int) -> NSBitmapImageRep {
    let rep = makeBitmap(size)   // 透明底，只画白色立方体；背景交给 icon.json 的 fill
    let S = CGFloat(size)
    drawing(rep) {
        for (path, alpha) in cubeFaces(canvasSize: S, widthRatio: CGFloat(glyphWidthRatio)) {
            NSColor.white.withAlphaComponent(alpha).setFill()
            path.fill()
        }
    }
    return rep
}

func srgbSpec(_ c: NSColor) -> String {
    let r = c.usingColorSpace(.sRGB)!
    return String(format: "srgb:%.5f,%.5f,%.5f,%.5f",
                  Double(r.redComponent), Double(r.greenComponent),
                  Double(r.blueComponent), Double(r.alphaComponent))
}

@discardableResult
func savePNG(_ rep: NSBitmapImageRep, _ path: String) throws -> Bool {
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    return FileManager.default.createFile(atPath: path, contents: data)
}

// MARK: - 主流程

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let fm = FileManager.default
let outURL = URL(fileURLWithPath: outDir)
try? fm.createDirectory(at: outURL, withIntermediateDirectories: true)

// --- 1. .icns 母版 ---
let master = renderFullIcon(size: Int(canvas), gradient: lightGradient)
_ = try savePNG(master, outDir + "/AppIcon.png")
print("  AppIcon.png            \(Int(canvas))x\(Int(canvas))")

// --- 2. 分层 .icon ---
let iconDir = outDir + "/AppIcon.icon"
let assetsDir = iconDir + "/Assets"
try? fm.removeItem(atPath: iconDir)
try fm.createDirectory(atPath: assetsDir, withIntermediateDirectories: true)

let glyphRep = renderGlyph(size: Int(canvas))
guard try savePNG(glyphRep, assetsDir + "/glyph.png") else {
    FileHandle.standardError.write("glyph.png 写入失败\n".data(using: .utf8)!)
    exit(1)
}

// 只写 fill-specializations（浅色在前作为基准，dark 为深色特化）
//
// 深色特化用 **solid 纯黑**，与 c2api / wb2api 保持一致：
// 纯黑底 + 白色立方体在深色桌面上对比最干脆，也避免任何色相残留
// （早先用低饱和深灰蓝渐变，仍会被看出偏色）。
let fillSpecs: [[String: Any]] = [
    ["value": ["linear-gradient": lightGradient.map(srgbSpec)]],
    ["appearance": "dark", "value": ["solid": srgbSpec(darkSolidFill)]],
]
let iconJSON: [String: Any] = [
    "fill-specializations": fillSpecs,
    "groups": [
        ["layers": [["image-name": "glyph.png", "name": "Container"]]]
    ],
    "supported-platforms": ["squares": ["macOS"]],
]
let jsonData = try JSONSerialization.data(withJSONObject: iconJSON, options: [.prettyPrinted, .sortedKeys])
try jsonData.write(to: URL(fileURLWithPath: iconDir + "/icon.json"))
print("  AppIcon.icon/icon.json  fill-specializations: light + dark")

// --- 3. 各尺寸 PNG，交给 iconutil 组 .icns ---
let iconset = outDir + "/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// (文件名, 像素边长)——每个尺寸都重新矢量绘制，比缩放母版更锐利
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in variants {
    let rep = renderFullIcon(size: px, gradient: lightGradient)
    try writePNG(rep, to: URL(fileURLWithPath: iconset + "/" + name))
}
print("  AppIcon.iconset/        \(variants.count) 个尺寸")

// 用 iconutil 组装 .icns
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset, "-o", outDir + "/AppIcon.icns"]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil 失败（退出码 \(proc.terminationStatus)）\n".data(using: .utf8)!)
    exit(1)
}
let icnsSize = ((try? fm.attributesOfItem(atPath: outDir + "/AppIcon.icns"))?[.size] as? Int) ?? 0
print("  AppIcon.icns           \(icnsSize / 1024) KB")
