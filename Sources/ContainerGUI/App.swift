import SwiftUI
import AppKit

/// 主窗口标识，供菜单栏图标「打开主界面」复用同一个窗口
enum WindowID {
    static let main = "main"
}

@main
struct ContainerGUIApp: App {
    @StateObject private var store = AppStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Apple Container", id: WindowID.main) {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1000, minHeight: 640)
                .background(WindowAccessor())
                .background(OpenWindowRegistrar())
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("刷新") { Task { await store.refreshAll() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        // 菜单栏图标由 AppKit 的 StatusItemController 管理（见 StatusItemController.swift）。
        // 这里不能用 SwiftUI 的 MenuBarExtra：它的点击类型由系统接管，
        // 左右键都弹同一个菜单，无法实现「左键开主界面、右键弹菜单」。

        Settings {
            SettingsView()
                .environmentObject(store)
                .frame(width: 460, height: 420)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 程序坞图标要尽早定下来，放 didFinishLaunching 会闪一下
    func applicationWillFinishLaunching(_ notification: Notification) {
        DockIconPreference.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppStore.shared.start()
        // 菜单栏图标自己接管左右键：左键开主界面，右键弹菜单
        StatusItemController.shared.install()
    }

    /// 关掉主窗口只收窗口，不退出应用 —— 菜单栏图标和服务都继续留着。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 点程序坞图标时把主窗口拉回来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return true
    }
}
