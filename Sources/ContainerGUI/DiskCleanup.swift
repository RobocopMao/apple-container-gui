import Foundation

/// 「哪里占着磁盘、哪些能清」的扫描与清理。
///
/// 背景：总览页原先直接把 `container system df` 的 reclaimable 显示出来，
/// 但那是**整套多平台镜像**的体积，用户看不懂为什么镜像页只有几百 MB。
/// 真正的原因是两套口径差了一个数量级：
///
/// - 镜像页 / `image ls` 里的 `variants[].size` 是**压缩后的下载体积**（几百 MB）
/// - 磁盘上实际存的是**每个平台各自解包后的完整文件系统**（每个 1 GB 上下）
///
/// 拉一个多平台镜像会把所有架构都解包落盘（实测拉 alpine 时日志里出现
/// `Unpacking image for platform linux/s390x` 等），所以 `node:12-alpine`
/// 这种 6 平台镜像会占 7 GB 左右，而它只用得上 arm64。
///
/// 这里按**磁盘真实占用**（快照目录的分配大小）重新算每个镜像的体积，
/// 并区分「有容器在用」与「可以安全删掉」。
enum DiskCleanup {

    // MARK: - 路径

    private static var appRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.container", isDirectory: true)
    }

    private static var snapshotsDir: URL { appRoot.appendingPathComponent("snapshots", isDirectory: true) }
    private static var containersDir: URL { appRoot.appendingPathComponent("containers", isDirectory: true) }

    // MARK: - 模型

    /// 一个可清理项
    struct Item: Identifiable, Hashable {
        enum Kind: Hashable {
            case image          // 未使用的镜像，用 `container image delete` 删
            case orphanSnapshot // 磁盘上有、但没有任何镜像/容器引用的快照
            case stoppedContainer
        }

        var id: String
        var kind: Kind
        /// 主标题，例如 `node:12-alpine`
        var title: String
        /// 补充说明，例如「6 个平台 · 只用得到 arm64」
        var subtitle: String
        /// 磁盘真实占用
        var bytes: Int64
        /// 是否有容器正在使用（true 时不给删）
        var inUse: Bool
        /// 传给 `container image delete` 的引用名（可能多个，如 node 有两个仓库名）
        var deleteNames: [String] = []
        /// 孤立快照的目录（直接删目录，没有官方命令）
        var snapshotPath: URL?

        static func == (l: Item, r: Item) -> Bool { l.id == r.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    /// 一次扫描的完整结果
    struct Scan {
        var items: [Item] = []
        /// 全部可清理字节数（不含 inUse）
        var reclaimableBytes: Int64 = 0
        /// 镜像占用的总字节
        var imageBytes: Int64 = 0
        /// 每个镜像引用名 -> 磁盘真实占用，供镜像页显示真实体积
        var imageDiskBytes: [String: Int64] = [:]
    }

    // MARK: - 扫描

    /// 扫描磁盘，算出每个镜像的真实占用与可清理项。
    /// 需要读取 `~/Library/Application Support/com.apple.container`，在 GUI 进程里跑没问题。
    static func scan(containers: [ContainerInfo], images: [ImageInfo]) -> Scan {
        var scan = Scan()

        // 0) 各镜像的 variant digest（含所有平台，这是体积差异的来源）
        let variants = loadVariants()

        // 1) 快照目录 -> 分配大小
        let snapshotSizes = measureSnapshots()

        // 2) 容器在用哪些快照（容器目录的 runtime-configuration.json 会引用根快照）
        var usedSnapshotDirs = Set<String>()
        var usedImageRefs = Set<String>()
        for c in containers {
            usedImageRefs.insert(c.image)
            usedImageRefs.insert(c.shortImage)
            let rc = containersDir.appendingPathComponent(c.id).appendingPathComponent("runtime-configuration.json")
            if let text = try? String(contentsOf: rc, encoding: .utf8) {
                for dir in snapshotSizes.keys where text.contains(dir) {
                    usedSnapshotDirs.insert(dir)
                }
            }
        }

        // 3) 按「同一 index digest」聚合镜像（node 有两个仓库名指向同一镜像，体积不能重复计）
        var grouped: [String: [ImageInfo]] = [:]
        var order: [String] = []
        for img in images {
            if grouped[img.id] == nil { order.append(img.id) }
            grouped[img.id, default: []].append(img)
        }

        // 哪些 variant digest 属于某个镜像
        var variantOwner: [String: String] = [:]   // variant digest -> index digest
        for (indexDigest, group) in grouped {
            for img in group {
                for varDigest in (variants[img.fullReference] ?? []) {
                    variantOwner[varDigest] = indexDigest
                }
            }
        }

        // 系统镜像（vminit / builder-shim）不在 image ls 里，但它们的快照必须保护起来，
        // 否则会被下面的孤立判断当成垃圾。只登记「有主」，不参与用户镜像的体积计算。
        var systemBytes: Int64 = 0
        for (key, digests) in variants where key.hasPrefix("system:") {
            // 系统镜像只有它自己那批 digest 属于它；只要它与某个用户镜像重叠就不重复计
            let unique = digests.filter { variantOwner[$0] == nil }
            for d in unique { variantOwner[d] = key }
            systemBytes += unique.reduce(Int64(0)) { $0 + (snapshotSizes[$1] ?? 0) }
        }
        scan.imageBytes += systemBytes

        for indexDigest in order {
            guard let group = grouped[indexDigest] else { continue }
            let names = group.map(\.fullReference)
            // 多个仓库名指向同一个 index 时，它们的 variants 是同一批 digest。
            // 必须先去重再求和，否则同一个镜像会被算两遍（实测会正好翻倍）。
            let varDigests = Array(Set(group.flatMap { variants[$0.fullReference] ?? [] }))
            let bytes = varDigests.reduce(Int64(0)) { $0 + (snapshotSizes[$1] ?? 0) }

            for n in names { scan.imageDiskBytes[n] = bytes }
            scan.imageBytes += bytes

            let inUse = group.contains { img in
                usedImageRefs.contains(img.fullReference)
                    || usedImageRefs.contains(img.reference)
                    || usedImageRefs.contains(img.shortName)
                    || varDigests.contains { usedSnapshotDirs.contains($0) }
            }

            // 同一镜像可能有多个仓库名（如同一个 node 从两个 registry 拉过），
            // 取最短的那个做标题，最清爽
            let title = group.map(\.fullReference).min { $0.count < $1.count } ?? indexDigest
            var notes: [String] = []
            if group.count > 1 { notes.append("\(group.count) 个仓库名") }
            if varDigests.count > 1 { notes.append("\(varDigests.count) 个平台") }
            notes.append(Format.bytes(bytes))

            scan.items.append(Item(
                id: indexDigest,
                kind: .image,
                title: title,
                subtitle: notes.joined(separator: " · "),
                bytes: bytes,
                inUse: inUse,
                deleteNames: group.map(\.fullReference)
            ))

            if !inUse { scan.reclaimableBytes += bytes }
        }

        // 4) 磁盘上有、但没有任何镜像引用的孤立快照
        for (dir, size) in snapshotSizes where variantOwner[dir] == nil {
            // 被容器当作初始文件系统引用的不算孤立
            guard !usedSnapshotDirs.contains(dir) else { continue }
            scan.items.append(Item(
                id: "orphan:\(dir)",
                kind: .orphanSnapshot,
                title: "孤立快照 \(String(dir.prefix(12)))…",
                subtitle: "没有任何镜像或容器引用",
                bytes: size,
                inUse: false,
                snapshotPath: snapshotsDir.appendingPathComponent(dir)
            ))
            scan.reclaimableBytes += size
        }

        // 大件排前面，在用的沉底
        scan.items.sort {
            if $0.inUse != $1.inUse { return !$0.inUse }
            return $0.bytes > $1.bytes
        }
        return scan
    }

    // MARK: - 执行删除

    /// 删除一批可清理项。返回 (释放的字节数, 错误信息列表)
    static func remove(_ items: [Item], cli: ContainerCLI = .shared) -> (freed: Int64, errors: [String]) {
        var freed: Int64 = 0
        var errors: [String] = []

        let images = items.filter { $0.kind == .image }
        let names = images.flatMap(\.deleteNames)
        if !names.isEmpty {
            let r = try? cli.run(["image", "delete", "--force"] + names)
            if let r, !r.ok {
                // 删除失败时不要在 UI 上谎称释放了空间
                errors.append(r.errorMessage)
            } else {
                freed += images.reduce(Int64(0)) { $0 + $1.bytes }
            }
        }

        // 孤立快照没有官方命令，只能删目录
        for it in items where it.kind == .orphanSnapshot {
            guard let p = it.snapshotPath else { continue }
            do {
                try FileManager.default.removeItem(at: p)
                freed += it.bytes
            } catch {
                errors.append("删除孤立快照失败：\(error.localizedDescription)")
            }
        }

        return (freed, errors)
    }

    // MARK: - 内部工具

    /// 递归累加目录里每个文件的**分配大小**（等价于 `du -sk`，稀疏文件也算得准）
    private static func allocatedSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let en = FileManager.default.enumerator(at: url,
                                                      includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    private static func measureSnapshots() -> [String: Int64] {
        var out: [String: Int64] = [:]
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: snapshotsDir,
                                                                    includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles]) else { return out }
        for d in dirs {
            guard (try? d.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if d.lastPathComponent == "ingest" { continue }
            out[d.lastPathComponent] = allocatedSize(d)
        }
        return out
    }

    /// 从 `image ls --format json` 取「镜像引用名 -> 各平台 variant digest」。
    /// `ImageInfo` 没保留 variants，所以这里一次性问回来，避免用可变的静态缓存。
    /// scan 会被放到后台线程调用，用局部字典比静态变量安全。
    ///
    /// ⚠️ 还必须补上 `state.json` 里的**系统镜像**（`vminit`、`container-builder-shim/builder`）：
    /// `image ls` 有意不列它们，但它们的快照实实在在占着磁盘。漏掉它们会把
    /// 「系统镜像的变体」误判成孤立快照而删掉 —— 实测 builder 的 arm64 变体
    /// （98a8ea79…）就差点被当垃圾清理，删掉会破坏镜像构建能力。
    private static func loadVariants() -> [String: [String]] {
        var out: [String: [String]] = [:]

        // 1) 用户镜像
        if let r = try? ContainerCLI.shared.run(["image", "ls", "--format", "json"]),
           let data = r.stdout.data(using: .utf8),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for d in raw {
                guard let cfg = d["configuration"] as? [String: Any],
                      let name = cfg["name"] as? String else { continue }
                out[name] = (d["variants"] as? [[String: Any]] ?? []).compactMap { v -> String? in
                    guard let dg = v["digest"] as? String else { return nil }
                    return dg.replacingOccurrences(of: "sha256:", with: "")
                }
            }
        }

        // 2) 系统镜像：state.json 列出全部镜像（含 image ls 隐藏的），
        //    但**只取 image ls 里没有的**，避免把用户镜像的 index manifest 当成
        //    实际解包内容（index manifest 会列出 amd64/arm64/attestation 等好几个
        //    digest，而磁盘上只解包了实际用到的那个平台，混进来会重复计数）。
        for (ref, digests) in systemImageVariants() where out[ref] == nil {
            out["system:" + ref] = digests
        }
        return out
    }

    /// 读 state.json + content/blobs，展开**系统镜像**（image ls 不列的那些）的 variant digest
    private static func systemImageVariants() -> [String: [String]] {
        var out: [String: [String]] = [:]
        let stateURL = appRoot.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return out }
        let blobs = appRoot.appendingPathComponent("content/blobs/sha256", isDirectory: true)

        for (ref, info) in state {
            guard let dict = info as? [String: Any],
                  let indexDigest = (dict["digest"] as? String)?
                    .replacingOccurrences(of: "sha256:", with: "") else { continue }
            guard let blob = try? Data(contentsOf: blobs.appendingPathComponent(indexDigest)),
                  let manifest = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
                  let manifests = manifest["manifests"] as? [[String: Any]] else { continue }
            out[ref] = manifests.compactMap { m in
                (m["digest"] as? String)?.replacingOccurrences(of: "sha256:", with: "")
            }
        }
        return out
    }
}
