import SwiftUI

// MARK: - 总览

struct DashboardView: View {
    @EnvironmentObject var store: AppStore

    @State private var showCleanup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let s = store.system, !s.running {
                    // 服务没运行：容器/镜像/磁盘都读不到，只给引导，不显示任何数字
                    serviceWarning
                } else {
                    statCards
                    diskSection
                    quickActions
                }
            }
            .padding(20)
        }
        .background(.background)
        .navigationTitle("总览")
        .sheet(isPresented: $showCleanup) {
            CleanupView().environmentObject(store)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apple container 控制台")
                .font(.largeTitle).fontWeight(.semibold)
            HStack(spacing: 12) {
                if let s = store.system {
                    Label(s.running ? "服务运行中" : "服务未启动",
                          systemImage: s.running ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(s.running ? .green : .red)
                        .font(.callout)

                    // 服务没运行时没有可信的版本号/系统信息，整块不显示
                    if s.running {
                        Text("版本 \(s.serverVersion)").font(.callout).foregroundStyle(.secondary)
                        Text(s.hostOS).font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text("正在读取服务状态…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var serviceWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("容器服务没有运行").font(.callout).fontWeight(.medium)
                Text("需要先启动后台服务才能创建和运行容器。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("启动服务") { store.startSystem() }
                .buttonStyle(.borderedProminent)
                .disabled(store.isBusy)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var statCards: some View {
        HStack(spacing: 12) {
            StatCard(
                title: "容器",
                value: "\(store.runningContainers.count) / \(store.containers.count)",
                subtitle: "运行中 / 总数",
                icon: "shippingbox.fill",
                color: .blue
            )
            StatCard(
                title: "镜像",
                value: "\(store.images.count)",
                subtitle: "本地镜像",
                icon: "square.stack.3d.up.fill",
                color: .purple
            )
            StatCard(
                title: "磁盘占用",
                value: store.disk.map { Format.bytes($0.totalSize) } ?? "—",
                subtitle: store.disk.map { "可回收 \(Format.bytes($0.totalReclaimable))" } ?? "统计中",
                icon: "internaldrive.fill",
                color: .orange
            )
            StatCard(
                title: "CPU 核心",
                value: store.system.map { "\($0.cpus)" } ?? "—",
                subtitle: "宿主机可用",
                icon: "cpu",
                color: .green
            )
        }
    }

    @ViewBuilder
    private var diskSection: some View {
        if let d = store.disk {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("磁盘明细").font(.headline)
                    Spacer()
                    Button {
                        showCleanup = true
                    } label: {
                        Label("清理…", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(store.isBusy)
                }

                VStack(spacing: 0) {
                    // df 的 total 包含 Apple 的系统镜像（ghcr.io/apple/containerization/vminit），
                    // 而 image ls 只列用户自己拉的镜像，所以两个数必然对不上。
                    // 这里显示 df 的真实总数，并标注其中有多少是系统镜像。
                    DiskRow(
                        name: "镜像",
                        category: d.images,
                        note: systemImageNote(d.images.total)
                    )
                    Divider()
                    DiskRow(name: "容器", category: d.containers)
                    Divider()
                    DiskRow(name: "数据卷", category: d.volumes)
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

                if d.images.reclaimableBytes > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(.orange)
                        Text("有 \(Format.bytes(d.images.reclaimableBytes)) 可以释放。")
                            .font(.caption)
                        Button("查看哪里能清理…") { showCleanup = true }
                            .buttonStyle(.link)
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.top, 2)
                }

                Text("说明：磁盘占用按解包后的真实体积统计。一个多平台镜像会把所有架构都解包落盘，因此「镜像」页里的下载体积会比这里小一个数量级；「镜像」总数也包含 Apple 运行容器所需的系统镜像。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 磁盘上的镜像数减去用户可见镜像数，就是系统镜像数
    private func systemImageNote(_ diskTotal: Int) -> String? {
        let systemCount = diskTotal - store.images.count
        guard systemCount > 0 else { return nil }
        return "含 \(systemCount) 个系统镜像"
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快捷操作").font(.headline)

            HStack(spacing: 10) {
                Button {
                    showCleanup = true
                } label: {
                    Label("清理磁盘…", systemImage: "trash")
                }
                .disabled(store.isBusy)

                Button {
                    store.pruneContainers()
                } label: {
                    Label("清理已停止容器", systemImage: "shippingbox")
                }
                .disabled(store.isBusy)

                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label("刷新数据", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)

                Spacer()
            }
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            Text(value).font(.title2).fontWeight(.semibold)
            Text(subtitle).font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DiskRow: View {
    let name: String
    let category: DiskCategory
    /// 可选的补充说明，例如「含 1 个系统镜像」
    var note: String? = nil

    var body: some View {
        HStack {
            Text(name).frame(width: 70, alignment: .leading)
            Text("\(category.total) 项").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(Format.bytes(category.sizeBytes)).frame(width: 100, alignment: .leading)

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
            if category.reclaimableBytes > 0 {
                Text("可回收 \(Format.bytes(category.reclaimableBytes))")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
