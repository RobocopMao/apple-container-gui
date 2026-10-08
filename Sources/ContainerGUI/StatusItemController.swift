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

    /// 「系统一失活就抢回激活」的观察者
    private var reclaimObserver: NSObjectProtocol?

    private override init() { super.init() }

    /// 诊断日志：仅在设置了环境变量 `CGUI_DIAG` 时写文件，平时零开销、零输出。
    nonisolated static func diag(_ msg: String) {
        guard ProcessInfo.processInfo.environment["CGUI_DIAG"] != nil else { return }
        let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, msg)
        let path = "/tmp/statusclick.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 安装

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // 左右键都要回调给我们，才有机会分辨。
            //
            // 左键挂 mouseUp（不要改成 mouseDown）：实测挂 mouseDown 反而更糟 ——
            // 系统是在动作回调**之后**才把应用置为非激活，应用再也回不来（失活后
            // 一直不恢复，暗帧永久留下）。挂 mouseUp 时系统先失活、我们在回调里
            // `NSApp.activate` 再抢回来，中间的暗帧只有几十毫秒。
            // 右键也用 mouseUp：`showMenu()` 里的 performClick 需要一个完整的点击。
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        menu.autoenablesItems = false
        menu.delegate = self

        updateAppearance()
        installReclaimObserver()

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

    // MARK: - 消除点击状态项时的「闪一下」

    /// 问题现象：应用在**前台**、且以 `.accessory`（隐藏程序坞图标）策略运行时，
    /// 左键点菜单栏图标会让整个窗口闪一下。
    ///
    /// 实测根因（非推测）：
    /// - 点菜单栏会让应用**失去激活**（macOS 固有行为：点空白菜单栏也照样失活，
    ///   且不会自动恢复）。`isActive` 实测 `true → false → true`，失活窗口正好等于
    ///   「鼠标按下到抬起」的时长；窗口像素在同一时刻出现一帧变暗
    ///   （mean 93.16 → 92.75、bright 75216 → 74925），因为窗口画的是非激活外观。
    /// - 我们在 `statusItemClicked`（挂的是 mouseUp）里调 `NSApp.activate` 把它抢回来，
    ///   所以失活只维持到 mouseUp —— 但那一帧暗色已经被画出来了，这就是用户看到的「闪」。
    /// - 挂 `.leftMouseDown` **更糟**：系统是在动作回调**之后**才失活，这样回调里的
    ///   `NSApp.activate` 白做，应用再也回不来（暗帧永久留下）。所以动作继续挂 mouseUp。
    /// - `.regular` 策略下系统根本不会失活（实测 2696 次采样零跳变），
    ///   所以这是 `.accessory` 特有的问题。
    ///
    /// 对策：不等 mouseUp，而是**盯着「失活」这个事实本身**，一发生就立刻抢回激活。
    ///
    /// 用 `willResignActive`（最早的那个钩子）而不是 `didResignActive`：实测灰帧
    /// 17–18ms vs 20–21ms。抢激活要趁系统还没来得及绘制非激活外观。
    ///
    /// **绝不要在这里调 `window.display()`**：实测同步重画会把灰帧从 20ms 拉到
    /// 100–150ms —— 重画时应用往往仍处于非激活态，等于把灰帧抢先画到屏幕上并停留。
    /// 抢回激活就够了，系统的重绘在下一个显示周期自然完成。
    ///
    /// **判定「是不是在点我们的状态项」必须用鼠标位置，不能用事件**（本 bug 最深的坑）：
    /// 曾经用 `NSEvent.addLocalMonitorForEvents(.leftMouseDown)` 置位一个 `reclaimArmed`
    /// 标志，结果整个修复形同虚设、肉眼毫无变化（仍闪 89–108ms）。带 `CGUI_DIAG` 的日志
    /// 给出决定性证据：
    ///
    ///     1791469744.918 willResignActive armed=false
    ///     1791469745.010 armReclaim OK evType=1     ← 迟了 92ms
    ///
    /// 即系统**先**让应用失活、**之后**才把 mouseDown 投递给本地监听器。任何「等事件
    /// 来置位」的方案都注定晚一步，抢激活的分支永远不会执行。鼠标位置在失活那一刻就是
    /// 可用的，没有时序问题；并且它自带「只在点状态项时才抢」的过滤 —— 用户去点别的
    /// 应用时鼠标不在状态项范围内，绝不会被我们抢走焦点。
    private func installReclaimObserver() {
        reclaimObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reclaimActivationIfPointingAtStatusItem() }
        }
    }

    private func reclaimActivationIfPointingAtStatusItem() {
        guard let button = statusItem?.button, let bw = button.window else { return }
        // 只看鼠标位置，不看事件：系统是先失活、后投递 mouseDown，等事件必晚一步。
        guard bw.frame.contains(NSEvent.mouseLocation) else { return }
        // 再要求「此刻确实有鼠标键按着」。位置检查本身已足够修掉闪烁，这一条是为了挡住
        // 一个更隐蔽的误伤：用户只是把光标停在状态项上、然后用 Cmd+Tab 切走 —— 那种失活
        // 与「点我们的图标」毫无关系，不该被我们抢回来（否则应用会赖在前台切不走）。
        guard NSEvent.pressedMouseButtons != 0 else { return }
        NSApp.activate(ignoringOtherApps: true)
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

        // 这里原本有个「显示程序坞图标」开关，已删：程序坞图标改成跟着窗口自动走
        // （窗口开着就显示、关掉就收起，见 DockIcon.swift）。
        // 手动切到 .accessory 恰恰是「前台点菜单栏图标会闪」的根源 —— 实测同类点击
        // .accessory 会闪 89–108ms、.regular 完全不闪，所以不能再让用户把它关掉。

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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
