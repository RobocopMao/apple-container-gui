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

        // 状态栏图标：常驻菜单栏。主窗口关掉后它还在，容器和服务都继续跑。
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(store)
        } label: {
            MenuBarLabel()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.menu)

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
    }

    /// 关掉主窗口只收窗口，不退出应用 —— 菜单栏图标和服务都继续留着。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 点程序坞图标时把主窗口拉回来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return true
    }
}
