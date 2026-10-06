import AppKit
import SwiftUI

// MARK: - 菜单栏图标与菜单

// 说明：菜单栏图标原来用 SwiftUI 的 `MenuBarExtra`（MenuBarLabel / MenuBarContent）
// 实现，但它无法区分左右键点击（两种点击都由系统接管）。现已改为 AppKit 的
// `StatusItemController`（见 StatusItemController.swift），实现
// 「左键打开主界面、右键弹出菜单」。

// MARK: - 主窗口抓手

/// 记住主窗口的 NSWindow 和 SwiftUI 的 openWindow，
/// 让「打开主界面」和点程序坞图标都复用同一个窗口，而不是越开越多。
@MainActor
enum MainWindow {
    static weak var window: NSWindow?
    static var openWindow: ((String) -> Void)?
    /// SwiftUI 的打开设置窗口方式（由 OpenWindowRegistrar 桥接进来）
    static var openSettings: (() -> Void)?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        if let open = openWindow {
            open(WindowID.main)
            return
        }
        // 兜底：还没抓到 openWindow 时，先把现有窗口找出来
        if let w = NSApp.windows.first(where: { $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        }
    }

    /// 打开设置窗口。
    /// 优先用 SwiftUI 桥接过来的方式（可靠）；取不到时退回旧的 responder 链。
    static func showSettings() {
        if let open = openSettings {
            NSApp.activate(ignoringOtherApps: true)
            open()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    /// 主窗口是否可见（供刷新节奏判断）
    static var isVisible: Bool {
        if let w = window { return w.isVisible }
        return NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    }
}

/// 把主窗口的 NSWindow 记到 MainWindow 里
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { MainWindow.window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { MainWindow.window = nsView.window }
    }
}

/// 捕获 SwiftUI 的 `openWindow` 交给 MainWindow。
///
/// 以前这份活儿是菜单栏标签（MenuBarLabel）顺手做的；现在菜单栏改由 AppKit
/// 的 StatusItemController 管理，就把捕获点挪到主窗口这里 —— 它一定存在，
/// 而且「窗口被关掉后再要打开窗口」的场景本来就依赖它。
///
/// 顺带把 `openSettings` 也桥接出来：AppKit 的菜单项拿不到 SwiftUI 环境值，
/// 而 `NSApp.sendAction(showSettingsWindow:)` 在这里不生效（实测点了没反应），
/// 所以要靠这个视图把 SwiftUI 自己的打开方式交出来。
struct OpenWindowRegistrar: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .onAppear {
                MainWindow.openWindow = { id in openWindow(id: id) }
                MainWindow.openSettings = { openSettings() }
            }
    }
}
