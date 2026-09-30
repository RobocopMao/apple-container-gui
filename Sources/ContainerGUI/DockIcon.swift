import AppKit

/// 程序坞（Dock）图标开关。
///
/// - `true`  → `.regular`：程序坞里有图标，也有 App 菜单
/// - `false` → `.accessory`：只留菜单栏图标，主窗口照常能开
///
/// 选择存在 UserDefaults，下次启动沿用。
enum DockIconPreference {
    private static let key = "showDockIcon"

    /// 默认显示，与加菜单栏图标之前的行为一致
    static var isVisible: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func store(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: key)
    }

    @MainActor
    static func apply() { apply(isVisible) }

    @MainActor
    static func apply(_ visible: Bool) {
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }
}
