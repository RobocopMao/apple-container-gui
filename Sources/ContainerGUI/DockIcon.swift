import AppKit

/// 程序坞（Dock）图标策略：**跟着窗口走**，不再手动开关。
///
/// - 有窗口在屏幕上（或最小化在程序坞里）→ `.regular`：程序坞有图标，也正常出现在 Cmd+Tab
/// - 窗口全关掉                            → `.accessory`：只剩菜单栏图标
///
/// **为什么取消手动开关**：手动关掉程序坞图标 = 应用以 `.accessory` 策略运行，而
/// `.accessory` 有个副作用 —— 应用在前台时点菜单栏图标，系统会先夺走激活、再由我们抢回来，
/// 中间系统会画出**一帧「非激活外观」**（交通灯变灰、标题栏和侧边栏变暗），这就是用户看到的
/// 「闪一下」。实测：同类点击 `.accessory` 灰 89–108ms、`.regular` 灰 0ms（同一二进制，
/// 只改这一个开关）。
///
/// 改成按窗口自动切换后，窗口开着时一定是 `.regular`，系统根本不会失活，闪烁从根上消失；
/// 窗口关掉时没有窗口可闪，正好切回 `.accessory` 收起程序坞图标。
@MainActor
enum DockIconPolicy {
    private static var installed = false
    private static var pending = false
    /// 本次运行里是否已经出现过带标题的窗口。
    /// 启动早期窗口还没建出来，这时**不能**因为「没窗口」就收起图标 —— 否则每次启动
    /// 程序坞图标都会先消失再出现（实测启动时先降 `.accessory`、281ms 后才升回 `.regular`）。
    private static var hasEverSeenWindow = false

    /// 「有窗口」的判定：可见的窗口，或最小化在程序坞里的窗口。
    ///
    /// - 只认 `.titled` 的窗口（主窗口、设置窗口），这样能自动排除菜单栏状态项自己那个
    ///   无标题的窗口 —— 它永远「可见」，不然策略会永远停在 `.regular`；顺带也排除了
    ///   选择镜像用的 popover。
    /// - 最小化的窗口也算「有窗口」：否则一最小化就切 `.accessory`，程序坞里那个最小化
    ///   缩略图会连图标一起消失，窗口再也点不回来。
    static var hasOnScreenWindow: Bool {
        NSApp.windows.contains { w in
            guard w.styleMask.contains(.titled) else { return false }
            return w.isVisible || w.isMiniaturized
        }
    }

    /// 装上观察者，并立刻按现状对一次。
    static func install() {
        guard !installed else { return }
        installed = true

        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.willCloseNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DockIconPolicy.syncSoon() }
            }
        }

        syncSoon()
    }

    /// 窗口马上要出现时提前切到 `.regular`（含程序坞图标），
    /// 让窗口第一帧就是正常外观，不必等窗口就位后的通知。
    static func windowWillAppear() {
        apply(.regular)
    }

    /// 延后一轮 runloop 再同步。
    ///
    /// `willClose` 是在窗口真正关掉**之前**发的，此刻 `isVisible` 仍是 true，当场判定会
    /// 得出「还有窗口」的错误结论，必须延一轮才读得到关闭后的状态。同一轮里触发多次只算一次。
    static func syncSoon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async {
            pending = false
            syncNow()
        }
    }

    /// 立刻按现状切换。
    static func syncNow() {
        let hasWindow = hasOnScreenWindow
        if hasWindow { hasEverSeenWindow = true }

        // 还没见过窗口（启动早期）就保持 `.regular`，不要提前收起图标：
        // 此刻「没窗口」只是窗口还没建出来，不是用户把窗口关掉了。
        // 只有「见过窗口、现在又都没有了」才真的该收起。
        let policy: NSApplication.ActivationPolicy =
            (hasWindow || !hasEverSeenWindow) ? .regular : .accessory

        dumpInventory(chosen: policy, hasWindow: hasWindow)
        apply(policy)
    }

    private static func apply(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    /// 诊断：仅在设置了环境变量 `CGUI_DIAG` 时把窗口清单写进日志，
    /// 用来核对「哪些窗口算数」这个判定本身（平时零开销）。
    private static func dumpInventory(chosen: NSApplication.ActivationPolicy, hasWindow: Bool) {
        guard ProcessInfo.processInfo.environment["CGUI_DIAG"] != nil else { return }
        var lines = [
            "policy -> \(chosen == .regular ? "regular(有窗口)" : "accessory(无窗口)")"
            + " 有窗口=\(hasWindow) 见过窗口=\(hasEverSeenWindow)"
        ]
        for w in NSApp.windows {
            lines.append(
                "  win \(type(of: w)) mask=\(String(w.styleMask.rawValue, radix: 16))"
                + " vis=\(w.isVisible) mini=\(w.isMiniaturized) main=\(w.canBecomeMain)"
                + " frame=\(w.frame) title=\(w.title)"
            )
        }
        StatusItemController.diag(lines.joined(separator: "\n"))
    }
}
