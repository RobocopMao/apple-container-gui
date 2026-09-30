import SwiftUI
import AppKit

// MARK: - 日志窗口

struct LogWindowView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let container: ContainerInfo

    @State private var text: String = ""
    @State private var lineCount = 500
    @State private var autoScroll = true
    @State private var autoRefresh = true
    @State private var loading = false
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "加载中…" : text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: text) { _, _ in
                    if autoScroll {
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }

            Divider()
            footer
        }
        .frame(width: 820, height: 580)
        .onAppear {
            Task { await load() }
            startTimer()
        }
        .onDisappear { timer?.invalidate() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title3).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("容器日志 · \(container.id)").font(.headline)
                Text(container.shortImage).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if container.state == .running {
                Label("运行中", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label("已停止", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Toggle("自动刷新", isOn: $autoRefresh)
                .onChange(of: autoRefresh) { _, on in
                    if on { startTimer() } else { timer?.invalidate(); timer = nil }
                }
            Toggle("自动滚动", isOn: $autoScroll)

            Picker("行数", selection: $lineCount) {
                Text("100").tag(100)
                Text("500").tag(500)
                Text("1000").tag(1000)
                Text("全部").tag(0)
            }
            .frame(width: 130)
            .onChange(of: lineCount) { _, _ in Task { await load() } }

            if loading { ProgressView().controlSize(.small) }

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }

            Button {
                Task { await load() }
            } label: {
                Label("立即刷新", systemImage: "arrow.clockwise")
            }

            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func startTimer() {
        timer?.invalidate()
        guard autoRefresh else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in await load() }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        let out = await store.fetchLogs(container, lines: lineCount)
        // 避免无变化时反复触发滚动
        if out != text { text = out }
        loading = false
    }
}

// MARK: - 镜像列表

struct ImageListView: View {
    @EnvironmentObject var store: AppStore
    @State private var pullSheet = false
    @State private var pullText = ""
    @State private var confirmDelete: ImageInfo?

    var body: some View {
        Group {
            if let s = store.system, !s.running {
                ServiceDownView(title: "容器服务未启动")
            } else if store.images.isEmpty {
                ContentUnavailableView {
                    Label("本地没有镜像", systemImage: "square.stack.3d.up")
                } description: {
                    Text("拉取一个镜像，例如 nginx:alpine 或 alpine:3.22。")
                } actions: {
                    Button("拉取镜像") { pullSheet = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                table
            }
        }
        .navigationTitle("镜像")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    pullSheet = true
                } label: {
                    Label("拉取镜像", systemImage: "arrow.down.circle")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)
            }
        }
        .sheet(isPresented: $pullSheet) {
            pullSheetView
        }
        .alert("删除镜像？", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        ), presenting: confirmDelete) { img in
            Button("删除", role: .destructive) {
                store.deleteImage(img)
                confirmDelete = nil
            }
            Button("取消", role: .cancel) { confirmDelete = nil }
        } message: { img in
            Text("镜像「\(img.shortName):\(img.tag)」将被删除，占用空间会释放。")
        }
    }

    private var table: some View {
        Table(store.images) {
            TableColumn("名称") { img in
                HStack(spacing: 7) {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(.purple)
                        .font(.caption)
                    Text(img.shortName).fontWeight(.medium)
                }
            }
            .width(min: 130, ideal: 190)

            TableColumn("标签") { img in
                Text(img.tag)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            .width(min: 60, ideal: 90)

            TableColumn("架构") { img in
                Text(img.architecture.isEmpty ? "—" : img.architecture)
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 65)

            TableColumn("大小") { img in
                Text(img.sizeDisplay)
                    .font(.system(.caption, design: .monospaced))
            }
            .width(min: 65, ideal: 85)

            TableColumn("创建时间") { img in
                Text(Format.relative(img.created))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .width(min: 80, ideal: 110)

            TableColumn("操作") { img in
                HStack(spacing: 6) {
                    Button {
                        runFromImage(img)
                    } label: {
                        Label("运行", systemImage: "play.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("用这个镜像快速创建一个容器")

                    Button {
                        confirmDelete = img
                    } label: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("删除镜像")
                }
                .disabled(store.isBusy)
            }
            .width(min: 110, ideal: 140)
        }
        .contextMenu(forSelectionType: String.self) { _ in
        }
    }

    private var pullSheetView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("拉取镜像").font(.headline)
                    Text("从容器仓库下载到本地").font(.caption).foregroundStyle(.secondary)
                }
            }

            TextField("例如 nginx:alpine、alpine:3.22、python:3.12-slim", text: $pullText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { doPull() }

            VStack(alignment: .leading, spacing: 6) {
                Text("常用镜像").font(.caption).foregroundStyle(.secondary)
                FlowRow(items: ["alpine:3.22", "nginx:alpine", "redis:alpine", "postgres:16", "python:3.12-slim", "node:22-alpine", "ubuntu:24.04"]) { item in
                    Button(item) { pullText = item }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            HStack {
                Spacer()
                Button("取消") { pullSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("拉取") { doPull() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pullText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func doPull() {
        store.pullImage(pullText)
        pullSheet = false
    }

    private func runFromImage(_ img: ImageInfo) {
        var spec = NewContainerSpec()
        spec.image = img.fullReference
        store.runContainer(spec)
    }
}

/// 简单的流式布局容器
struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        // 用 grid 近似流式布局，避免依赖 Layout 复杂度
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}
