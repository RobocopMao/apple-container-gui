import SwiftUI

enum NavSection: String, CaseIterable, Identifiable {
    case dashboard = "总览"
    case containers = "容器"
    case images = "镜像"
    case settings = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.up"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @State private var selection: NavSection = .containers

    var body: some View {
        NavigationSplitView {
            List(NavSection.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 240)
            .safeAreaInset(edge: .bottom) {
                SidebarStatus()
            }
        } detail: {
            Group {
                switch selection {
                case .dashboard: DashboardView()
                case .containers: ContainerListView()
                case .images: ImageListView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) { TaskToast() }
        .alert("出错了", isPresented: Binding(
            get: { store.errorBanner != nil },
            set: { if !$0 { store.errorBanner = nil } }
        )) {
            Button("知道了", role: .cancel) { store.errorBanner = nil }
        } message: {
            Text(store.errorBanner ?? "")
        }
    }
}

/// 侧边栏底部的服务状态
struct SidebarStatus: View {
    @EnvironmentObject var store: AppStore

    private var running: Bool? {
        store.system.map(\.running)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()

            HStack(spacing: 7) {
                Circle()
                    .fill(serviceColor)
                    .frame(width: 8, height: 8)
                Text(serviceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 2)

            // 服务没运行时没有可信的版本号，整块不显示
            if let s = store.system, s.running, s.serverVersion != "—" {
                Text("v\(s.serverVersion) · \(s.architecture)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        // 与上方侧边栏列表保持同一背景（不加 .bar 材质，避免出现色差横带）
        .background(Color.clear)
    }

    private var serviceColor: Color {
        guard let r = running else { return .gray }
        return r ? .green : .red
    }

    private var serviceText: String {
        guard let r = running else { return "未连接" }
        return r ? "服务运行中" : "服务未启动"
    }
}

/// 底部操作提示条
struct TaskToast: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        if let t = store.taskStatus {
            HStack(spacing: 10) {
                if store.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: t.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(t.isError ? .orange : .green)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.callout).fontWeight(.medium)
                    if !t.detail.isEmpty {
                        Text(t.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }

                if t.finished && !store.isBusy {
                    Button {
                        withAnimation { store.taskStatus = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: store.taskStatus)
        }
    }
}
