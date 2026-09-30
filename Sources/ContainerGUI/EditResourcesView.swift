import SwiftUI

/// 「编辑资源」弹窗：只调 CPU 核数与内存，其余参数一概不动。
struct EditResourcesView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let container: ContainerInfo

    @State private var cpus: Int = 2
    @State private var memoryMB: Int = 1024
    @State private var loadError: String?
    @State private var loaded = false

    /// 宿主 CPU 核数（作为上限参考）
    private let hostCPUs = ProcessInfo.processInfo.processorCount

    private var wasRunning: Bool { container.state == .running }

    private var changed: Bool {
        cpus != originalCPUs || memoryMB != originalMemoryMB
    }

    @State private var originalCPUs = 0
    @State private var originalMemoryMB = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let e = loadError {
                errorBody(e)
            } else {
                form
            }

            Divider()
            footer
        }
        .frame(width: 420)
        .onAppear(perform: load)
    }

    // MARK: - 区块

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("编辑资源").font(.headline)
                Text(container.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("CPU 核心")
                    Spacer()
                    Text("\(cpus) 核")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Stepper("", value: $cpus, in: 1...max(hostCPUs, 1))
                    .labelsHidden()
                Text("本机共 \(hostCPUs) 核")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("内存")
                    Spacer()
                    Text(memoryText)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(memoryMB) },
                    set: { memoryMB = Int($0) }
                ), in: 256...32768, step: 256)
                HStack(spacing: 6) {
                    ForEach([512, 1024, 2048, 4096, 8192], id: \.self) { mb in
                        Button(mb >= 1024 ? "\(mb / 1024)G" : "\(mb)M") {
                            memoryMB = mb
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                }
            }

            if wasRunning {
                Label("该容器正在运行，保存后会先停止再重新启动，期间服务会短暂中断。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
    }

    private func errorBody(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("无法读取配置", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("该容器可能不是通过 CLI 创建的，或配置目录已被移动。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
    }

    private var footer: some View {
        HStack {
            if changed {
                Text("原为 \(originalCPUs) 核 / \(memoryTextOf(originalMemoryMB))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("保存并应用") { apply() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(loadError != nil || !changed || store.isBusy)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - 逻辑

    private var memoryText: String { memoryTextOf(memoryMB) }

    private func memoryTextOf(_ mb: Int) -> String {
        mb >= 1024 && mb % 1024 == 0 ? "\(mb / 1024) GB" : "\(mb) MB"
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        do {
            let l = try ContainerResources.read(container.id)
            cpus = l.cpus
            memoryMB = l.memoryMB >= 256 ? l.memoryMB : 256
            originalCPUs = l.cpus
            originalMemoryMB = l.memoryMB
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func apply() {
        store.applyResources(container, cpus: cpus, memoryMB: memoryMB) { ok in
            if ok { dismiss() }
        }
    }
}
