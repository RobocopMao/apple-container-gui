import SwiftUI

/// 「清理磁盘」弹窗：列出每一项占用了多少、哪些能删，勾选后清理。
struct CleanupView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<String> = []
    @State private var scan: DiskCleanup.Scan?
    @State private var confirm = false

    private var items: [DiskCleanup.Item] { scan?.items ?? [] }
    private var cleanable: [DiskCleanup.Item] { items.filter { !$0.inUse } }

    private var selectedBytes: Int64 {
        cleanable.filter { selected.contains($0.id) }.reduce(Int64(0)) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let s = scan {
                if s.items.isEmpty {
                    emptyState
                } else {
                    list(s)
                }
            } else {
                loading
            }

            Divider()
            footer
        }
        .frame(width: 620, height: 520)
        .onAppear(perform: rescan)
        .alert("确认清理？", isPresented: $confirm) {
            Button("删除", role: .destructive) { performCleanup() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: - 区块

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("清理磁盘").font(.headline)
                if let s = scan {
                    Text("镜像共占 \(Format.bytes(s.imageBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("正在扫描…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                rescan()
            } label: {
                Label("重新扫描", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(store.isBusy)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在统计磁盘占用…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("没有可清理的内容", systemImage: "checkmark.circle")
        } description: {
            Text("磁盘上没有被占用的镜像或快照。")
        }
        .frame(maxHeight: .infinity)
    }

    private func list(_ s: DiskCleanup.Scan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 顶部：全选行动区
                HStack(spacing: 10) {
                    Button("全选可清理项") {
                        selected = Set(cleanable.map(\.id))
                    }
                    .controlSize(.small)
                    .disabled(cleanable.isEmpty)

                    Button("全不选") { selected.removeAll() }
                        .controlSize(.small)
                        .disabled(selected.isEmpty)

                    Spacer()

                    if s.reclaimableBytes > 0 {
                        Text("可释放 \(Format.bytes(s.reclaimableBytes))")
                            .font(.callout).fontWeight(.medium)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)

                Divider()

                ForEach(Array(s.items.enumerated()), id: \.element.id) { idx, item in
                    CleanupRow(
                        item: item,
                        checked: Binding(
                            get: { selected.contains(item.id) },
                            set: { on in
                                if on { selected.insert(item.id) } else { selected.remove(item.id) }
                            }
                        )
                    )
                    if idx < s.items.count - 1 { Divider().padding(.leading, 18) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if scan != nil {
                Text(selected.isEmpty
                     ? "勾选要清理的项目"
                     : "将释放约 \(Format.bytes(selectedBytes))")
                    .font(.callout)
                    .foregroundStyle(selected.isEmpty ? .secondary : .primary)
            }
            Spacer()
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("清理选中项") { confirm = true }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || store.isBusy)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - 逻辑

    private func rescan() {
        Task {
            let s = await store.scanDisk()
            scan = s
            // 默认勾上「可清理」的镜像项，但孤立快照不默认勾（比较激进）
            selected = Set(s.items.filter { !$0.inUse && $0.kind == .image }.map(\.id))
        }
    }

    /// 确认框里逐项列出将删除的东西，避免误删
    private var confirmMessage: String {
        let chosen = cleanable.filter { selected.contains($0.id) }
        var lines = ["以下 \(chosen.count) 项将被删除，共释放约 \(Format.bytes(selectedBytes))：", ""]
        for it in chosen {
            lines.append("· \(it.title)（\(Format.bytes(it.bytes))）")
        }
        lines.append("")
        lines.append("删除后需要时得重新拉取镜像。正在使用的镜像不会被删除。")
        return lines.joined(separator: "\n")
    }

    private func performCleanup() {
        let chosen = cleanable.filter { selected.contains($0.id) }
        store.cleanup(chosen) { _ in
            rescan()
        }
    }
}

// MARK: - 单行

private struct CleanupRow: View {
    let item: DiskCleanup.Item
    @Binding var checked: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $checked)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(item.inUse)

            Image(systemName: icon)
                .foregroundStyle(item.inUse ? Color.secondary : Color.orange)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.inUse {
                        Text("使用中")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.kind == .orphanSnapshot {
                    Text("没有官方命令能删它，将直接移除该快照目录。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            Text(Format.bytes(item.bytes))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(item.inUse ? .secondary : .primary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !item.inUse else { return }
            checked.toggle()
        }
    }

    private var icon: String {
        switch item.kind {
        case .image: return "square.stack.3d.up.fill"
        case .orphanSnapshot: return "questionmark.folder.fill"
        case .stoppedContainer: return "shippingbox"
        }
    }
}
