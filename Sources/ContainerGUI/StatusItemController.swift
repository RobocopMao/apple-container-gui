import AppKit
import Combine

/// 菜单栏状态项。
///
/// **为什么不用 SwiftUI 的 `MenuBarExtra`**：它的点击类型由系统接管，
/// 左键和右键都会弹出同一个菜单，**无法区分**。这里需要「左键开主界面、
/// 右键弹菜单」，所以只能用 AppKit 的 `NSStatusItem` 自己接管点击、
/// 通过 `NSApp.currentEvent` 判断是哪个键。
///
/// 关键手法：不要常挂 `statusItem.menu`（一挂上，左右键就都变成弹菜单，
/// 再也没机会区分）。而是在右键时「临时挂上 menu → 触发一次点击 → 摘掉」。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()

    private let store = AppStore.shared
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()

    private override init() { super.init() }

    // MARK: - 安装

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // 左右键都要回调给我们，才有机会分辨
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        menu.autoenablesItems = false
        menu.delegate = self

        updateAppearance()

        // 数据变了就同步图标（实心/线框）和计数。
        // objectWillChange 在变更**之前**发出，所以延到下一轮 runloop 再读新值。
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateAppearance() }
            }
            .store(in: &cancellables)
    }

    // MARK: - 图标与计数

    private func updateAppearance() {
        guard let button = statusItem?.button else { return }
        let runningCount = store.runningContainers.count
        let active = store.system?.running == true && runningCount > 0

        button.image = CubeGlyph.menuBarImage(active: active)
        if runningCount > 0 {
            button.title = " \(runningCount)"
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    // MARK: - 点击分流

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        // 右键、或按住 Control 点左键，都按右键处理（macOS 惯例）
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isRightClick {
            showMenu()
        } else {
            MainWindow.show()
        }
    }

    /// 临时挂上菜单弹出，弹完立刻摘掉 —— 否则左右键都会弹菜单。
    private func showMenu() {
        rebuildMenu()
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    // MARK: - 菜单内容

    /// 每次弹出前重建，保证勾选状态和容器列表都是最新的。
    private func rebuildMenu() {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        let serviceRunning = store.system?.running == true
        add("启动服务", #selector(startService), enabled: !serviceRunning && !store.isBusy)
        add("停止服务", #selector(stopService), enabled: serviceRunning && !store.isBusy)
        add("刷新", #selector(refresh), enabled: !store.isBusy)

        menu.addItem(.separator())

        addContainerSection()

        menu.addItem(.separator())

        add("打开主界面", #selector(openMain), enabled: true)
        // ⚠️ 选择器名不能叫 openSettings：macOS 把这个名字当标准动作，
        // 会给菜单项**自动配一个设置齿轮图标**（实测：只有这个名字有图标，
        // 换成 openSettingsXXX / showSettingsWindow: / showSettings 等都没有），
        // 导致这一行比别的行多出图标、显得不统一。所以刻意换个不撞系统约定的名字。
        add("设置…", #selector(showOurSettings), enabled: true)

        let dockItem = NSMenuItem(
            title: "显示程序坞图标",
            action: #selector(toggleDockIcon),
            keyEquivalent: ""
        )
        dockItem.target = self
        dockItem.state = store.showDockIcon ? .on : .off
        dockItem.isEnabled = true
        menu.addItem(dockItem)

        menu.addItem(.separator())
        add("退出 Apple Container", #selector(quit), enabled: true)
    }

    private func addContainerSection() {
        if store.system?.running != true {
            disabledItem("启动服务后才能管理容器")
        } else if store.containers.isEmpty {
            disabledItem("暂无容器")
        } else {
            menu.addItem(.sectionHeader(title: "容器"))
            // 运行中的排前面，一眼看到能停哪个
            for c in orderedContainers {
                let running = c.state == .running
                let item = NSMenuItem(
                    title: running ? "停止 \(c.id)" : "启动 \(c.id)",
                    action: #selector(toggleContainer(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = c.id
                item.image = NSImage(
                    systemSymbolName: running ? "stop.circle" : "play.circle",
                    accessibilityDescription: nil
                )
                item.isEnabled = !store.isBusy
                menu.addItem(item)
            }
        }
    }

    private func add(_ title: String, _ action: Selector, enabled: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func disabledItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private var statusLine: String {
        guard let s = store.system else { return "正在读取服务状态…" }
        guard s.running else { return "服务未启动" }
        return "服务运行中 · \(store.runningContainers.count)/\(store.containers.count) 个容器在跑"
    }

    private var orderedContainers: [ContainerInfo] {
        store.containers.sorted {
            let l = $0.state == .running, r = $1.state == .running
            if l != r { return l }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    // MARK: - 菜单动作

    @objc private func startService() { store.startSystem() }
    @objc private func stopService() { store.stopSystem() }
    @objc private func refresh() { Task { await store.refreshAll() } }
    @objc private func openMain() { MainWindow.show() }

    @objc private func toggleContainer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let c = store.containers.first(where: { $0.id == id }) else { return }
        if c.state == .running {
            store.stopContainer(c)
        } else {
            store.startContainer(c)
        }
    }

    /// 打开设置窗口。
    /// 名字刻意不叫 `openSettings` —— 那个名字会被系统当成标准动作并自动配上图标
    /// （见菜单构建处的说明），这里只负责调用。
    @objc private func showOurSettings() {
        MainWindow.showSettings()
    }

    @objc private func toggleDockIcon() {
        store.setShowDockIcon(!store.showDockIcon)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
