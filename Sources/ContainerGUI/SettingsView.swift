import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Section {
                Toggle("自动刷新", isOn: Binding(
                    get: { store.autoRefresh },
                    set: { store.setAutoRefresh($0) }
                ))

                HStack {
                    Text("刷新间隔")
                    Slider(
                        value: Binding(
                            get: { store.refreshInterval },
                            set: { store.refreshInterval = $0; store.restartRefreshTimer() }
                        ),
                        in: 1...15,
                        step: 1
                    )
                    Text(String(format: "%.0f 秒", store.refreshInterval))
                        .font(.system(.callout, design: .monospaced))
                        .frame(width: 54, alignment: .trailing)
                }
                .disabled(!store.autoRefresh)
            } header: {
                Text("刷新")
            }

            Section {
                Toggle("列表中显示已停止的容器", isOn: $store.showStopped)
            } header: {
                Text("显示")
            }

            Section {
                Toggle("在程序坞中显示图标", isOn: Binding(
                    get: { store.showDockIcon },
                    set: { store.setShowDockIcon($0) }
                ))
                Text("关掉后只保留菜单栏图标。主窗口和后台服务都不受影响；关掉主窗口，服务也照常运行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("菜单栏")
            }

            if let s = store.system {
                Section {
                    LabeledContent("服务状态", value: s.running ? "运行中" : "未启动")

                    // 服务没运行时读不到真实版本，整块不显示（避免出现「—」）
                    if s.running {
                        LabeledContent("服务版本", value: s.serverVersion)
                        LabeledContent("客户端版本", value: s.clientVersion)
                        LabeledContent("系统版本", value: s.hostOS)
                        LabeledContent("架构", value: s.architecture)
                        LabeledContent("CPU 核心", value: "\(s.cpus)")
                        LabeledContent("容器总数", value: "\(s.containersTotal)")
                        LabeledContent("镜像总数", value: "\(s.imagesTotal)")
                    }
                } header: {
                    Text("系统信息")
                }

                Section {
                    HStack {
                        Button("启动服务") { store.startSystem() }
                            .disabled(store.isBusy || s.running)
                        Button("停止服务") { store.stopSystem() }
                            .disabled(store.isBusy || !s.running)
                        Spacer()
                    }
                    Text("停止服务会中断所有正在运行的容器。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("服务控制")
                }
            } else {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在读取…").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("系统信息")
                }
            }

            Section {
                HStack {
                    Text("container 路径")
                    Spacer()
                    Text(ContainerCLI.shared.executablePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("本应用通过调用 Apple 官方的 container 命令行工具来管理容器。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("高级")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
    }
}
