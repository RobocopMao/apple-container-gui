import SwiftUI

// MARK: - 容器列表

struct ContainerListView: View {
    @EnvironmentObject var store: AppStore
    @State private var showNewSheet = false
    @State private var selectedID: String?
    @State private var confirmDelete: ContainerInfo?
    @State private var logTarget: ContainerInfo?
    @State private var editResources: ContainerInfo?

    var body: some View {
        Group {
            if let s = store.system, !s.running {
                ServiceDownView()
            } else if store.containers.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .navigationTitle("容器")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewSheet = true
                } label: {
                    Label("新建容器", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)
            }
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: Binding(
                    get: { store.showStopped },
                    set: { store.showStopped = $0 }
                )) {
                    Label("显示已停止", systemImage: "eye")
                }
                .toggleStyle(.button)
            }
        }
        .sheet(isPresented: $showNewSheet) {
            NewContainerView().environmentObject(store)
        }
        .sheet(item: $logTarget) { c in
            LogWindowView(container: c).environmentObject(store)
        }
        .sheet(item: $editResources) { c in
            EditResourcesView(container: c).environmentObject(store)
        }
        .alert("删除容器？", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        ), presenting: confirmDelete) { c in
            Button("删除", role: .destructive) {
                store.deleteContainer(c)
                confirmDelete = nil
            }
            Button("取消", role: .cancel) { confirmDelete = nil }
        } message: { c in
            Text("容器「\(c.id)」将被永久删除，容器内未挂载的数据会丢失。")
        }
        .onAppear {
            if selectedID == nil { selectedID = store.containers.first?.id }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有容器", systemImage: "shippingbox")
        } description: {
            Text("点击右上角「新建容器」，或者先到镜像页拉取一个镜像。")
        } actions: {
            Button("新建容器") { showNewSheet = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var table: some View {
        Table(store.visibleContainers, selection: $selectedID) {
            TableColumn("名称") { c in
                HStack(spacing: 7) {
                    Circle()
                        .fill(c.state == .running ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    Text(c.id).fontWeight(.medium)
                }
            }
            .width(min: 110, ideal: 150)

            TableColumn("镜像") { c in
                Text(c.shortImage).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 180)

            TableColumn("状态") { c in
                Text(c.state.label)
                    .foregroundStyle(c.state == .running ? .green : .secondary)
            }
            .width(min: 60, ideal: 70)

            TableColumn("端口") { c in
                Text(c.portsDisplay)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 160)

            TableColumn("IP") { c in
                Text(c.ipDisplay)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)

            TableColumn("CPU") { c in
                if let s = store.stats[c.id] {
                    Text(s.cpuDisplay).font(.system(.caption, design: .monospaced))
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 50, ideal: 65)

            TableColumn("内存") { c in
                if let s = store.stats[c.id], s.memoryUsageBytes > 0 {
                    Text(Format.bytes(Int64(s.memoryUsageBytes)))
                        .font(.system(.caption, design: .monospaced))
                } else {
                    Text(c.memoryDisplay).foregroundStyle(.tertiary)
                }
            }
            .width(min: 60, ideal: 80)

            TableColumn("操作") { c in
                ContainerRowActions(
                    store: store,
                    container: c,
                    onLogs: { logTarget = c },
                    onEdit: { editResources = c },
                    onDelete: { confirmDelete = c }
                )
            }
            .width(min: 150, ideal: 175)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let c = store.containers.first(where: { $0.id == id }) {
                ContainerContextMenu(
                    store: store,
                    container: c,
                    onLogs: { logTarget = c },
                    onEdit: { editResources = c },
                    onDelete: { confirmDelete = c }
                )
            }
        }
    }
}

// MARK: - 行内操作按钮

struct ContainerRowActions: View {
    /// 显式传入而不是 @EnvironmentObject：这一列渲染在 Table 单元格里，
    /// 隐藏已停止容器导致该行被移除时，SwiftUI 会在环境已脱离的上下文里重新求值本视图，
    /// 环境查找失败会直接 Fatal error 崩掉整个 App。
    @ObservedObject var store: AppStore
    let container: ContainerInfo
    let onLogs: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if container.state == .running {
                IconButton(icon: "stop.fill", help: "停止", tint: .orange) {
                    store.stopContainer(container)
                }
            } else {
                IconButton(icon: "play.fill", help: "启动", tint: .green) {
                    store.startContainer(container)
                }
            }

            IconButton(icon: "doc.text.magnifyingglass", help: "查看日志", tint: .blue, action: onLogs)

            IconButton(icon: "slider.horizontal.3", help: "编辑资源（CPU / 内存）", tint: .purple, action: onEdit)

            IconButton(icon: "trash", help: "删除", tint: .red, action: onDelete)
        }
        .buttonStyle(.borderless)
        .disabled(store.isBusy)
    }
}

struct IconButton: View {
    let icon: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovering ? tint.opacity(0.16) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - 右键菜单

struct ContainerContextMenu: View {
    /// 同 ContainerRowActions：菜单也在选择区上下文里求值，显式传入更稳。
    @ObservedObject var store: AppStore
    let container: ContainerInfo
    let onLogs: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        if container.state == .running {
            Button("停止") { store.stopContainer(container) }
            Button("重启") {
                store.stopContainer(container)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    store.startContainer(container)
                }
            }
            Divider()
        } else {
            Button("启动") { store.startContainer(container) }
            Divider()
        }
        Button("查看日志") { onLogs() }
        Button("编辑资源（CPU / 内存）…") { onEdit() }
        Divider()
        Button("复制容器名") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(container.id, forType: .string)
        }
        Divider()
        Button("删除", role: .destructive) { onDelete() }
    }
}
