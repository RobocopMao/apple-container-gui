import SwiftUI
import AppKit

// MARK: - 新建容器

struct NewContainerView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var spec = NewContainerSpec()
    @State private var portDrafts: [PortMapping] = []
    @State private var mountDrafts: [MountMapping] = []
    @State private var envDrafts: [EnvPair] = []

    @State private var newHostPort = ""
    @State private var newContainerPort = ""
    @State private var newMountSource = ""
    @State private var newMountDest = ""
    @State private var newEnvKey = ""
    @State private var newEnvValue = ""

    @State private var showAdvanced = false
    @State private var showImagePicker = false

    struct EnvPair: Identifiable, Hashable {
        var id = UUID()
        var key: String
        var value: String
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    basicSection
                    portsSection
                    mountsSection
                    envSection
                    advancedSection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }

            Divider()
            footer
        }
        .frame(width: 600, height: 560)
    }

    private var titleBar: some View {
        HStack {
            Image(systemName: "shippingbox.badge.plus")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("新建容器").font(.headline)
                Text("填写后会执行 container run").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    // MARK: 基础

    private var basicSection: some View {
        FormGroup(title: "基本信息", icon: "info.circle") {
            LabeledField(label: "镜像", required: true) {
                HStack(spacing: 8) {
                    TextField("例如 nginx:alpine", text: $spec.image)
                        .textFieldStyle(.roundedBorder)

                    // 用 Button + Popover 而不是 Menu：Menu 会自带一个下拉指示器，
                    // 再叠加自绘箭头就会显示成两个箭头。
                    Button {
                        showImagePicker.toggle()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 16)
                    }
                    .buttonStyle(.bordered)
                    .help("从本地镜像中选择")
                    .disabled(store.images.isEmpty)
                    .popover(isPresented: $showImagePicker, arrowEdge: .bottom) {
                        ImagePickerPopover(images: store.images) { ref in
                            spec.image = ref
                            showImagePicker = false
                        }
                    }
                }
            }
            Text("本地没有的镜像会自动从仓库拉取。")
                .font(.caption).foregroundStyle(.tertiary)

            LabeledField(label: "容器名称") {
                TextField("留空则自动生成", text: $spec.name)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: 端口

    private var portsSection: some View {
        FormGroup(title: "端口映射", icon: "arrow.left.arrow.right") {
            ForEach(portDrafts) { p in
                HStack {
                    Text(p.display).font(.system(.callout, design: .monospaced))
                    Spacer()
                    Button {
                        portDrafts.removeAll { $0.id == p.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                TextField("宿主端口", text: $newHostPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("容器端口", text: $newContainerPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                Button("添加") { addPort() }
                    .disabled(newHostPort.isEmpty || newContainerPort.isEmpty)
                Spacer()
            }

            Text("例如宿主 8080 → 容器 80，之后浏览器访问 localhost:8080。")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: 挂载

    private var mountsSection: some View {
        FormGroup(title: "目录挂载", icon: "folder") {
            ForEach(mountDrafts) { m in
                HStack {
                    Text(m.display)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        mountDrafts.removeAll { $0.id == m.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                TextField("Mac 上的路径", text: $newMountSource)
                    .textFieldStyle(.roundedBorder)
                Button {
                    chooseFolder { newMountSource = $0 }
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("选择文件夹")
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("容器内路径", text: $newMountDest)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                Button("添加") { addMount() }
                    .disabled(newMountSource.isEmpty || newMountDest.isEmpty)
            }
        }
    }

    // MARK: 环境变量

    private var envSection: some View {
        FormGroup(title: "环境变量", icon: "list.bullet.rectangle") {
            ForEach(envDrafts) { e in
                HStack {
                    Text("\(e.key)=\(e.value)")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        envDrafts.removeAll { $0.id == e.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                TextField("KEY", text: $newEnvKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                Text("=").foregroundStyle(.secondary)
                TextField("value", text: $newEnvValue)
                    .textFieldStyle(.roundedBorder)
                Button("添加") { addEnv() }
                    .disabled(newEnvKey.isEmpty)
            }
        }
    }

    // MARK: 高级

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                LabeledField(label: "CPU 核心") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(spec.cpus) },
                            set: { spec.cpus = Int($0) }
                        ), in: 1...Double(max(2, store.system?.cpus ?? 8)), step: 1)
                        Text("\(spec.cpus)").font(.system(.callout, design: .monospaced)).frame(width: 26)
                    }
                }

                LabeledField(label: "内存") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(spec.memoryMB) },
                            set: { spec.memoryMB = Int($0) }
                        ), in: 256...8192, step: 256)
                        Text(Format.bytes(Int64(spec.memoryMB) * 1024 * 1024))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 70, alignment: .trailing)
                    }
                }

                LabeledField(label: "启动命令") {
                    TextField("留空使用镜像默认命令，例如 nginx -g 'daemon off;'", text: $spec.command)
                        .textFieldStyle(.roundedBorder)
                }

                Toggle("后台运行（-d）", isOn: $spec.detach)
            }
            .padding(.top, 10)
        } label: {
            Label("高级选项", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
    }

    // MARK: 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 预览实际命令
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(.secondary).font(.caption)
                Text(commandPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commandPreview, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.plain)
                .help("复制命令")
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建容器") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(spec.image.trimmingCharacters(in: .whitespaces).isEmpty || store.isBusy)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var commandPreview: String {
        syncSpec()
        return "container " + spec.cliArguments.joined(separator: " ")
    }

    // MARK: 操作

    private func addPort() {
        guard let hp = Int(newHostPort), let cp = Int(newContainerPort) else { return }
        portDrafts.append(PortMapping(hostAddress: "0.0.0.0", hostPort: hp, containerPort: cp, proto: "tcp"))
        newHostPort = ""; newContainerPort = ""
    }

    private func addMount() {
        let src = (newMountSource as NSString).expandingTildeInPath
        mountDrafts.append(MountMapping(source: src, destination: newMountDest))
        newMountSource = ""; newMountDest = ""
    }

    private func addEnv() {
        let key = newEnvKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        envDrafts.append(EnvPair(key: key, value: newEnvValue))
        newEnvKey = ""; newEnvValue = ""
    }

    private func chooseFolder(_ done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择要挂载到容器里的 Mac 文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            done(url.path)
        }
    }

    private func syncSpec() {
        spec.ports = portDrafts
        spec.mounts = mountDrafts
        spec.environment = Dictionary(uniqueKeysWithValues: envDrafts.map { ($0.key, $0.value) })
    }

    private func create() {
        syncSpec()
        store.runContainer(spec) { _ in
            dismiss()
        }
    }
}

// MARK: - 小部件

/// 本地镜像选择浮层
struct ImagePickerPopover: View {
    let images: [ImageInfo]
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("本地镜像")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(images) { img in
                        Button {
                            onPick(img.fullReference)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "shippingbox.fill")
                                    .font(.caption)
                                    .foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(img.shortName)
                                        .font(.callout)
                                    Text("\(img.tag) · \(img.sizeDisplay)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .frame(width: 260)
    }
}

struct FormGroup<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct LabeledField<Content: View>: View {
    let label: String
    var required: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text(label).font(.callout).foregroundStyle(.secondary)
                if required { Text("*").foregroundStyle(.red) }
            }
            content
        }
    }
}
