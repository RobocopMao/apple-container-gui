import Foundation
import SwiftUI
import Combine
import AppKit

/// 一个后台操作的进度/结果描述
struct TaskStatus: Equatable {
    var title: String
    var detail: String = ""
    var isError: Bool = false
    var finished: Bool = false
}

/// 新建容器时收集的表单数据
struct NewContainerSpec {
    var image: String = ""
    var name: String = ""
    var ports: [PortMapping] = []
    var mounts: [MountMapping] = []
    var environment: [String: String] = [:]
    var cpus: Int = 2
    var memoryMB: Int = 1024
    var command: String = ""
    var detach: Bool = true

    var cliArguments: [String] {
        var args = ["run"]
        if detach { args.append("-d") }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty { args += ["--name", trimmedName] }
        for p in ports { args += ["-p", p.cliSpec] }
        for m in mounts { args += ["-v", "\(m.source):\(m.destination)"] }
        for (k, v) in environment.sorted(by: { $0.key < $1.key }) {
            args += ["-e", "\(k)=\(v)"]
        }
        args += ["-c", "\(cpus)"]
        args += ["-m", "\(memoryMB)M"]
        args.append(image.trimmingCharacters(in: .whitespaces))
        let cmd = command.trimmingCharacters(in: .whitespaces)
        if !cmd.isEmpty {
            args.append("/bin/sh")
            args += ["-c", cmd]
        }
        return args
    }
}

@MainActor
final class AppStore: ObservableObject {
    /// 菜单栏图标与主窗口共用同一个 store：窗口关掉后菜单栏还得继续刷新
    static let shared = AppStore()

    // 数据
    @Published var containers: [ContainerInfo] = []
    @Published var images: [ImageInfo] = []
    @Published var stats: [String: ContainerStats] = [:]
    @Published var disk: DiskUsage?
    @Published var system: SystemStatus?

    // 状态
    @Published var isLoading = false
    @Published var lastRefresh: Date?
    @Published var errorBanner: String?

    /// 底部操作提示。完成后自动消失，不需要手动点关闭。
    /// didSet 让所有赋值点（启动/停止/创建/拉取/清理…）都自动带上自动消隐，
    /// 不用在每个操作里各写一遍。
    @Published var taskStatus: TaskStatus? {
        didSet { scheduleToastAutoHide() }
    }

    @Published var isBusy = false

    /// 操作完成的提示停留多久后自动消失
    static let toastAutoHideDelay: TimeInterval = 3.0
    /// 提示代数：每次赋值 +1。延迟到点的闭包只认自己那一代，
    /// 避免「上一条提示的定时器」把下一条提示提前关掉。
    private var toastGeneration = 0
    private var toastHideWork: DispatchWorkItem?

    // 设置
    @Published var showStopped = true
    @Published var autoRefresh = true
    @Published var refreshInterval: Double = 3.0

    private var started = false

    private let cli = ContainerCLI.shared
    private var refreshTimer: Timer?
    private var streamTimer: Timer?
    private var cpuSamples: [String: (usec: Double, at: Date)] = [:]

    var runningContainers: [ContainerInfo] {
        containers.filter { $0.state == .running }
    }

    var visibleContainers: [ContainerInfo] {
        showStopped ? containers : containers.filter { $0.state == .running }
    }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true
        Task { await refreshAll() }
        // CPU/内存统计只有主窗口在用，窗口关了就不再采样，省得白跑
        streamTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isMainWindowVisible else { return }
                await self.refreshStatsOnly()
            }
        }
        restartRefreshTimer()
    }

    /// 只停自己的定时器，绝不碰服务 —— 关窗口不能影响正在跑的容器和后台服务。
    func stop() {
        refreshTimer?.invalidate(); refreshTimer = nil
        streamTimer?.invalidate(); streamTimer = nil
        started = false
    }

    /// 主窗口是否开着。菜单栏图标一直在，刷新节奏按它分档。
    var isMainWindowVisible: Bool {
        MainWindow.isVisible
    }

    func restartRefreshTimer() {
        refreshTimer?.invalidate()
        guard autoRefresh else { refreshTimer = nil; return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickRefresh() }
        }
    }

    /// 主窗口开着就按用户设的间隔刷；只剩菜单栏图标时降到 10 秒一次。
    private func tickRefresh() {
        guard !isBusy else { return }
        if !isMainWindowVisible, let last = lastRefresh, Date().timeIntervalSince(last) < 10 { return }
        Task { await refreshAll(silent: true) }
    }

    func setAutoRefresh(_ on: Bool) {
        autoRefresh = on
        restartRefreshTimer()
    }

    // MARK: - 提示自动消隐

    /// 操作完成后把底部提示收掉。
    /// - 只有 finished 的提示才排定消隐；进行中的提示要一直留着（那时还带转圈）。
    /// - 每次赋值都换一代，旧定时器作废，所以「连续操作」不会把新提示提前关掉。
    /// - 完成与失败一视同仁，都是 3 秒；失败详情另有 alert 兜底，不会因为提示消失就丢掉。
    private func scheduleToastAutoHide() {
        toastHideWork?.cancel()
        toastHideWork = nil
        toastGeneration += 1
        guard let t = taskStatus, t.finished else { return }

        let generation = toastGeneration
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // 只认自己那一代：期间若又有新提示（含新操作开始），说明已经换了内容，不许关。
                // 不必再看 isBusy —— 每个会置 isBusy 的操作都会同时改 taskStatus，代数必然变。
                guard self.toastGeneration == generation else { return }
                self.toastStatusPhaseOut()
            }
        }
        toastHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastAutoHideDelay, execute: work)
    }

    private func toastStatusPhaseOut() {
        toastHideWork?.cancel()
        toastHideWork = nil
        toastGeneration += 1   // 让在途的旧定时器彻底失效
        // 提示条自身的 .animation 随提示一起被移除，这里必须显式开事务，
        // 否则程序化消失会「啪」地闪掉、没有下滑淡出。
        withAnimation(.easeInOut(duration: 0.2)) {
            taskStatus = nil
        }
    }

    /// 手动关闭提示（右上角的 ×），同时作废待执行的自动消隐
    func dismissTaskStatus() {
        toastStatusPhaseOut()
    }

    // MARK: - 刷新

    /// - Parameter silent: true 表示后台自动刷新。不置 isLoading（不闪按钮、不显示进度），
    ///   且只在数据真有变化时才写回，避免每几秒无谓地重建视图。
    func refreshAll(silent: Bool = false) async {
        guard !isBusy else { return }
        if !silent { isLoading = true }
        defer { if !silent { isLoading = false } }

        // 先看服务状态：服务没起来时，容器/镜像/磁盘必然读取失败，
        // 直接给空态，既避免刷屏报错，也让界面干净地提示「服务未启动」。
        let newSystem = await loadSystem()
        if let s = newSystem {
            if self.system != s { self.system = s }
            guard s.running else {
                if !self.containers.isEmpty { self.containers = [] }
                if !self.images.isEmpty { self.images = [] }
                if !self.stats.isEmpty { self.stats = [:] }
                if self.disk != nil { self.disk = nil }
                lastRefresh = Date()
                return
            }
        }

        async let c = loadContainers()
        async let i = loadImages()
        async let d = loadDisk()

        let (newContainers, newImages, newDisk) = await (c, i, d)
        if self.containers != newContainers { self.containers = newContainers }
        if self.images != newImages { self.images = newImages }
        if self.disk != newDisk { self.disk = newDisk }
        lastRefresh = Date()
        await refreshStatsOnly()
    }

    func refreshStatsOnly() async {
        let running = runningContainers.map(\.id)
        guard !running.isEmpty else {
            if !stats.isEmpty { stats = [:] }
            return
        }
        let result = await background {
            try? self.cli.run(["stats", "--no-stream", "--format", "json"])
        }
        guard let r = result, r.ok else { return }
        var parsed = ContainerStats.parseList(r.stdout)
        let now = Date()

        // 计算 CPU 百分比：两次采样之间 CPU 时间增量 / 墙钟增量
        for idx in parsed.indices {
            let id = parsed[idx].id
            if let prev = cpuSamples[id] {
                let dUsec = parsed[idx].cpuUsageUsec - prev.usec
                let dSec = now.timeIntervalSince(prev.at)
                if dSec > 0 && dUsec >= 0 {
                    parsed[idx].cpuPercent = max(0, dUsec / 1_000_000.0 / dSec * 100.0)
                }
            }
            cpuSamples[id] = (parsed[idx].cpuUsageUsec, now)
        }
        // 清掉已不在运行的采样
        let liveIds = Set(parsed.map(\.id))
        cpuSamples = cpuSamples.filter { liveIds.contains($0.key) }

        self.stats = Dictionary(uniqueKeysWithValues: parsed.map { ($0.id, $0) })
    }

    private func loadContainers() async -> [ContainerInfo] {
        let r = await background { try? self.cli.run(["ls", "-a", "--format", "json"]) }
        guard let r, r.ok else { return containers }
        return ContainerInfo.parseList(r.stdout)
    }

    private func loadImages() async -> [ImageInfo] {
        let r = await background { try? self.cli.run(["image", "ls", "--format", "json"]) }
        guard let r, r.ok else { return images }
        return ImageInfo.parseList(r.stdout)
    }

    private func loadDisk() async -> DiskUsage? {
        let r = await background { try? self.cli.run(["system", "df", "--format", "json"]) }
        guard let r, r.ok else { return disk }
        return DiskUsage.parse(r.stdout)
    }

    private func loadSystem() async -> SystemStatus? {
        let r = await background { try? self.cli.run(["system", "status"]) }
        guard let r else { return nil }
        // 服务未启动时退出码为 1，提示信息在 stdout，这不是错误，要正常显示为「未启动」
        if r.ok { return SystemStatus.parse(r.stdout) }
        let text = r.combinedOutput
        if SystemStatus.isNotRunningMessage(text) {
            return SystemStatus.notRunning(message: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    // MARK: - 容器操作

    func startContainer(_ c: ContainerInfo) { perform("启动 \(c.id)") { ["start", c.id] } }
    func stopContainer(_ c: ContainerInfo) { perform("停止 \(c.id)") { ["stop", c.id] } }
    func killContainer(_ c: ContainerInfo, signal: String? = nil) {
        var args = ["kill"]
        if let signal { args += ["-s", signal] }
        args.append(c.id)
        perform("终止 \(c.id)") { args }
    }
    func deleteContainer(_ c: ContainerInfo, force: Bool = false) {
        var args = ["delete"]
        if force { args.append("--force") }
        args.append(c.id)
        perform("删除 \(c.id)") { args }
    }

    /// container 没有 restart 子命令，重启就是先 stop 再 start。
    func restartContainer(_ c: ContainerInfo) {
        Task {
            isBusy = true
            taskStatus = TaskStatus(title: "重启 \(c.id)", detail: "stop → start")
            _ = await background { try? self.cli.run(["stop", c.id]) }
            let r = await background { try? self.cli.run(["start", c.id]) }
            isBusy = false
            if let r, r.ok {
                taskStatus = TaskStatus(title: "已重启 \(c.id)", finished: true)
            } else {
                let msg = r?.errorMessage ?? "重启失败"
                taskStatus = TaskStatus(title: "重启 \(c.id) · 失败", detail: msg, isError: true, finished: true)
                errorBanner = msg
            }
            await refreshAll()
        }
    }

    func runContainer(_ spec: NewContainerSpec, onDone: ((String) -> Void)? = nil) {
        let args = spec.cliArguments
        guard !spec.image.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorBanner = "请填写镜像名称"
            return
        }
        Task {
            isBusy = true
            taskStatus = TaskStatus(title: "创建容器", detail: args.joined(separator: " "))
            let r = await background { try? self.cli.run(args) }
            isBusy = false

            if let r, r.ok {
                let id = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                taskStatus = TaskStatus(title: "容器已创建", detail: id, finished: true)
                onDone?(id)
                await refreshAll()
            } else {
                let msg = r?.errorMessage ?? "启动失败"
                taskStatus = TaskStatus(title: "创建失败", detail: msg, isError: true, finished: true)
                errorBanner = msg
            }
        }
    }

    /// 改已建容器的 CPU/内存。
    ///
    /// Apple container 没有 update 命令，参数固化在容器目录的 config.json 里，
    /// 所以这里直接改那份文件，再靠「停止 → 启动」让新值进 cgroup 生效。
    /// 实测：改完只需重启该容器，**不必重启整个容器服务**（那样会连累其他容器）。
    ///
    /// 注意：container ls / inspect 读的是 apiserver 缓存，会一直显示旧值，
    /// 因此这里改完直接把新值写进本地模型，界面立刻显示正确数字。
    func applyResources(_ c: ContainerInfo, cpus: Int, memoryMB: Int, onDone: @escaping (Bool) -> Void) {
        Task {
            isBusy = true
            let limits = ContainerResources.Limits(cpus: cpus, memoryMB: memoryMB)
            taskStatus = TaskStatus(title: "修改资源 \(c.id)",
                                    detail: "\(cpus) 核 · \(memoryMB) MB")

            let wasRunning = c.state == .running
            if wasRunning {
                _ = await background { try? self.cli.run(["stop", c.id]) }
            }

            let writeResult: String? = await background {
                do { try ContainerResources.write(c.id, limits: limits); return nil }
                catch { return error.localizedDescription }
            }

            if let err = writeResult {
                isBusy = false
                taskStatus = TaskStatus(title: "修改 \(c.id) · 失败", detail: err,
                                        isError: true, finished: true)
                errorBanner = err
                if wasRunning { _ = await background { try? self.cli.run(["start", c.id]) } }
                onDone(false)
                return
            }

            var startError: String?
            if wasRunning {
                let r = await background { try? self.cli.run(["start", c.id]) }
                if let r, !r.ok { startError = r.errorMessage }
            }
            isBusy = false

            // 界面立刻反映新值：apiserver 的缓存会让 ls 一直报旧数字
            if let idx = containers.firstIndex(where: { $0.id == c.id }) {
                containers[idx].cpus = cpus
                containers[idx].memoryBytes = limits.memoryBytes
            }

            if let err = startError {
                taskStatus = TaskStatus(title: "已改配置，但重启失败", detail: err,
                                        isError: true, finished: true)
                errorBanner = err
                onDone(true)
            } else {
                taskStatus = TaskStatus(title: "已更新 \(c.id) 资源",
                                        detail: "\(cpus) 核 · \(memoryMB) MB",
                                        finished: true)
                onDone(true)
            }
            await refreshAll()
        }
    }

    func execInContainer(_ c: ContainerInfo, command: String) async -> String {
        let r = await background {
            try? self.cli.run(["exec", c.id, "/bin/sh", "-c", command])
        }
        guard let r else { return "执行失败" }
        return r.combinedOutput.isEmpty ? (r.ok ? "(无输出)" : r.errorMessage) : r.combinedOutput
    }

    func fetchLogs(_ c: ContainerInfo, lines: Int) async -> String {
        let r = await background {
            try? self.cli.run(["logs", "-n", "\(lines)", c.id])
        }
        guard let r else { return "读取日志失败" }
        if r.stdout.isEmpty && !r.stderr.isEmpty { return r.stderr }
        return r.stdout.isEmpty ? "(暂无日志输出)" : r.stdout
    }

    // MARK: - 镜像操作

    func pullImage(_ reference: String) {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty else { errorBanner = "请填写镜像名称"; return }
        Task {
            isBusy = true
            taskStatus = TaskStatus(title: "拉取镜像", detail: ref)
            let r = await background { try? self.cli.run(["image", "pull", ref]) }
            isBusy = false
            if let r, r.ok {
                taskStatus = TaskStatus(title: "镜像已就绪", detail: ref, finished: true)
                await refreshAll()
            } else {
                let msg = r?.errorMessage ?? "拉取失败"
                taskStatus = TaskStatus(title: "拉取失败", detail: msg, isError: true, finished: true)
                errorBanner = msg
            }
        }
    }

    func deleteImage(_ img: ImageInfo) {
        perform("删除镜像 \(img.shortName)") { ["image", "delete", img.fullReference] }
    }

    func pruneContainers() {
        perform("清理已停止容器") { ["prune"] }
    }

    // MARK: - 磁盘清理

    /// 扫描磁盘占用（在后台线程算，避免卡界面）
    @Published var diskScan: DiskCleanup.Scan?

    func scanDisk() async -> DiskCleanup.Scan {
        // scan 里会调 container CLI（列 variants），必须挪到后台，否则卡住主线程
        let cs = containers, ims = images
        let s = await background { DiskCleanup.scan(containers: cs, images: ims) }
        diskScan = s
        return s
    }

    /// 执行清理
    func cleanup(_ items: [DiskCleanup.Item], onDone: @escaping (Int64) -> Void) {
        Task {
            isBusy = true
            let totalBytes = items.reduce(Int64(0)) { $0 + $1.bytes }
            taskStatus = TaskStatus(title: "清理磁盘", detail: "共 \(Format.bytes(totalBytes))")

            let result = await background { DiskCleanup.remove(items) }
            isBusy = false

            if result.errors.isEmpty {
                taskStatus = TaskStatus(title: "已释放 \(Format.bytes(result.freed))",
                                        finished: true)
            } else {
                taskStatus = TaskStatus(title: "部分清理完成",
                                        detail: result.errors.joined(separator: "；"),
                                        isError: true, finished: true)
                errorBanner = result.errors.joined(separator: "\n")
            }
            onDone(result.freed)
            await refreshAll()
        }
    }

    // MARK: - 系统操作

    func startSystem() { perform("启动容器服务") { ["system", "start"] } }
    func stopSystem() { perform("停止容器服务") { ["system", "stop"] } }

    // MARK: - 通用操作执行

    private func perform(_ title: String, args: @escaping () -> [String]) {
        Task {
            isBusy = true
            taskStatus = TaskStatus(title: title, detail: args().joined(separator: " "))
            let a = args()
            let r = await background { try? self.cli.run(a) }
            isBusy = false
            if let r, r.ok {
                taskStatus = TaskStatus(title: "\(title) · 完成", finished: true)
                await refreshAll()
            } else {
                let msg = r?.errorMessage ?? "操作失败"
                taskStatus = TaskStatus(title: "\(title) · 失败", detail: msg, isError: true, finished: true)
                errorBanner = msg
            }
        }
    }

    /// 把同步 CLI 调用挪到后台队列，避免卡住主线程
    private func background<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: work())
            }
        }
    }
}
