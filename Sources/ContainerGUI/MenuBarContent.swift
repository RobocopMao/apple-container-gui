import SwiftUI
import AppKit

// MARK: - 菜单栏图标

/// 菜单栏上的等距立方体 —— 与 App 图标中间那个立方体同一套几何。
/// 服务未运行或没有容器在跑时是线框，有容器在跑时是实心三面；
/// 旁边直接标出正在运行的容器数。
struct MenuBarLabel: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: CubeGlyph.menuBarImage(active: isActive))
            if store.runningContainers.count > 0 {
                Text("\(store.runningContainers.count)")
            }
        }
        // 图标常驻，趁它出现把 openWindow 存下来，好让点程序坞图标时也能开主窗口
        .task { MainWindow.openWindow = { id in openWindow(id: id) } }
    }

    /// 服务起来了、而且确实有容器在跑，才用实心立方体
    private var isActive: Bool {
        store.system?.running == true && !store.runningContainers.isEmpty
    }
}

// MARK: - 菜单内容

struct MenuBarContent: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) private var openWindow

    private var serviceRunning: Bool { store.system?.running == true }

    var body: some View {
        Text(statusLine)

        Divider()

        if serviceRunning {
            Button("停止服务") { store.stopSystem() }
                .disabled(store.isBusy)
        } else {
            Button("启动服务") { store.startSystem() }
                .disabled(store.isBusy)
        }

        Button("刷新") { Task { await store.refreshAll() } }
            .disabled(store.isBusy)

        Divider()

        containerSection

        Divider()

        Button("打开主界面") { openMainWindow() }

        SettingsLink { Text("设置…") }

        Toggle("显示程序坞图标", isOn: Binding(
            get: { store.showDockIcon },
            set: { store.setShowDockIcon($0) }
        ))

        Divider()

        Button("退出 Apple Container") { NSApp.terminate(nil) }
            .task { MainWindow.openWindow = { id in openWindow(id: id) } }
    }

    private var statusLine: String {
        guard let s = store.system else { return "正在读取服务状态…" }
        guard s.running else { return "服务未启动" }
        return "服务运行中 · \(store.runningContainers.count)/\(store.containers.count) 个容器在跑"
    }

    @ViewBuilder
    private var containerSection: some View {
        if !serviceRunning {
            Text("启动服务后才能管理容器")
        } else if store.containers.isEmpty {
            Text("暂无容器")
        } else {
            Section("容器") {
                ForEach(orderedContainers) { c in
                    Button {
                        toggle(c)
                    } label: {
                        Label(
                            c.state == .running ? "停止 \(c.id)" : "启动 \(c.id)",
                            systemImage: c.state == .running ? "stop.circle" : "play.circle"
                        )
                    }
                    .disabled(store.isBusy)
                }
            }
        }
    }

    /// 运行中的排前面，一眼看到能停哪个
    private var orderedContainers: [ContainerInfo] {
        store.containers.sorted {
            let l = $0.state == .running, r = $1.state == .running
            if l != r { return l }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    private func toggle(_ c: ContainerInfo) {
        if c.state == .running { store.stopContainer(c) } else { store.startContainer(c) }
    }

    private func openMainWindow() {
        MainWindow.openWindow = { id in openWindow(id: id) }
        MainWindow.show()
    }
}

// MARK: - 主窗口抓手

/// 记住主窗口的 NSWindow 和 SwiftUI 的 openWindow，
/// 让「打开主界面」和点程序坞图标都复用同一个窗口，而不是越开越多。
@MainActor
enum MainWindow {
    static weak var window: NSWindow?
    static var openWindow: ((String) -> Void)?

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
