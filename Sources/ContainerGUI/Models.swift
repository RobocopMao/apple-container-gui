import Foundation

// MARK: - 容器状态

enum ContainerState {
    case running
    case stopped
    case unknown

    init(raw: String?) {
        switch (raw ?? "").lowercased() {
        case "running": self = .running
        case "stopped", "exited", "created", "stopping": self = .stopped
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .running: return "运行中"
        case .stopped: return "已停止"
        case .unknown: return "未知"
        }
    }
}

// MARK: - 端口 / 挂载

struct PortMapping: Identifiable, Hashable {
    var id: String { "\(hostAddress):\(hostPort)->\(containerPort)/\(proto)" }
    var hostAddress: String
    var hostPort: Int
    var containerPort: Int
    var proto: String

    var display: String {
        let host = (hostAddress.isEmpty || hostAddress == "0.0.0.0") ? "" : "\(hostAddress):"
        return "\(host)\(hostPort) → \(containerPort)/\(proto)"
    }

    /// 用于生成 `-p` 参数
    var cliSpec: String {
        let host = (hostAddress.isEmpty || hostAddress == "0.0.0.0") ? "" : "\(hostAddress):"
        return "\(host)\(hostPort):\(containerPort)"
    }
}

struct MountMapping: Identifiable, Hashable {
    var id: String { "\(source)->\(destination)" }
    var source: String
    var destination: String

    var display: String { "\(source) → \(destination)" }
}

// MARK: - 容器

struct ContainerInfo: Identifiable, Hashable {
    var id: String
    var image: String
    var state: ContainerState
    var cpus: Int
    var memoryBytes: Int64
    var ipAddress: String?
    var startedDate: Date?
    var creationDate: Date?
    var ports: [PortMapping]
    var mounts: [MountMapping]
    var environment: [String]
    var command: [String]
    var architecture: String
    var os: String

    /// 去掉 docker.io/library/ 前缀，界面更干净
    var shortImage: String {
        var s = image
        for prefix in ["docker.io/library/", "docker.io/", "index.docker.io/library/"] {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)); break }
        }
        return s
    }

    var ipDisplay: String {
        guard let ip = ipAddress, !ip.isEmpty else { return "—" }
        return ip.split(separator: "/").first.map(String.init) ?? ip
    }

    var memoryDisplay: String { Format.bytes(memoryBytes) }

    var portsDisplay: String {
        ports.isEmpty ? "—" : ports.map(\.display).joined(separator: ", ")
    }

    static func parseList(_ json: String) -> [ContainerInfo] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return raw.compactMap(parse)
    }

    static func parse(_ dict: [String: Any]) -> ContainerInfo? {
        guard let cfg = dict.dict("configuration"),
              let id = cfg.str("id")
        else { return nil }

        let statusDict = dict.dict("status") ?? [:]
        let state = ContainerState(raw: statusDict.str("state"))

        // 端口
        let ports: [PortMapping] = (cfg.arr("publishedPorts") ?? []).compactMap { p in
            guard let cp = p.int("containerPort"), let hp = p.int("hostPort") else { return nil }
            return PortMapping(
                hostAddress: p.str("hostAddress") ?? "",
                hostPort: hp,
                containerPort: cp,
                proto: p.str("proto") ?? "tcp"
            )
        }

        // 挂载
        let mounts: [MountMapping] = (cfg.arr("mounts") ?? []).compactMap { m in
            guard let src = m.str("source"), let dst = m.str("destination") else { return nil }
            return MountMapping(source: src, destination: dst)
        }

        let initProc = cfg.dict("initProcess") ?? [:]
        let resources = cfg.dict("resources") ?? [:]
        let platform = cfg.dict("platform") ?? [:]
        let imageDict = cfg.dict("image") ?? [:]

        // 运行中容器的 IP
        var ip: String?
        if let nets = statusDict.arr("networks"), let first = nets.first {
            ip = first.str("ipv4Address")
        }

        return ContainerInfo(
            id: id,
            image: imageDict.str("reference") ?? "—",
            state: state,
            cpus: resources.int("cpus") ?? 0,
            memoryBytes: Int64(resources.int("memoryInBytes") ?? 0),
            ipAddress: ip,
            startedDate: Format.date(statusDict.str("startedDate")),
            creationDate: Format.date(cfg.str("creationDate")),
            ports: ports,
            mounts: mounts,
            environment: initProc.strArr("environment"),
            command: initProc.strArr("arguments"),
            architecture: platform.str("architecture") ?? "",
            os: platform.str("os") ?? ""
        )
    }
}

// MARK: - 镜像

struct ImageInfo: Identifiable, Hashable {
    var id: String
    var reference: String
    var repository: String
    var tag: String
    var architecture: String
    var sizeBytes: Int64
    var created: Date?
    var digest: String

    var shortName: String {
        var s = repository
        for prefix in ["docker.io/library/", "docker.io/", "index.docker.io/library/"] {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)); break }
        }
        return s
    }

    var sizeDisplay: String { Format.bytes(sizeBytes) }

    /// 完整的可引用名称（用于删除 / 运行）
    var fullReference: String {
        tag.isEmpty ? repository : "\(repository):\(tag)"
    }

    static func parseList(_ json: String) -> [ImageInfo] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return raw.compactMap { d -> ImageInfo? in
            guard let cfg = d.dict("configuration"),
                  let name = cfg.str("name")
            else { return nil }

            let (repo, tag) = Format.splitReference(name)

            var size: Int64 = 0
            var arch = ""
            if let variants = d.arr("variants"), let v = variants.first {
                size = Int64(v.int("size") ?? 0)
                if let p = v.dict("platform") { arch = p.str("architecture") ?? "" }
            }

            return ImageInfo(
                id: d.str("id") ?? name,
                reference: name,
                repository: repo,
                tag: tag,
                architecture: arch,
                sizeBytes: size,
                created: Format.date(cfg.str("creationDate")),
                digest: cfg.dict("descriptor").flatMap { $0.str("digest") } ?? ""
            )
        }
    }
}

// MARK: - 运行统计

struct ContainerStats: Identifiable, Hashable {
    var id: String
    var cpuUsageUsec: Double
    var cpuPercent: Double = 0
    var memoryUsageBytes: Double
    var memoryLimitBytes: Double
    var networkRxBytes: Double
    var networkTxBytes: Double
    var blockReadBytes: Double
    var blockWriteBytes: Double
    var numProcesses: Int

    var memoryDisplay: String {
        "\(Format.bytes(Int64(memoryUsageBytes))) / \(Format.bytes(Int64(memoryLimitBytes)))"
    }

    var memoryPercent: Double {
        guard memoryLimitBytes > 0 else { return 0 }
        return min(100, memoryUsageBytes / memoryLimitBytes * 100)
    }

    var cpuDisplay: String { String(format: "%.1f%%", cpuPercent) }

    static func parseList(_ json: String) -> [ContainerStats] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return raw.compactMap { d in
            guard let id = d.str("id") else { return nil }
            return ContainerStats(
                id: id,
                cpuUsageUsec: d.dbl("cpuUsageUsec") ?? 0,
                memoryUsageBytes: d.dbl("memoryUsageBytes") ?? 0,
                memoryLimitBytes: d.dbl("memoryLimitBytes") ?? 0,
                networkRxBytes: d.dbl("networkRxBytes") ?? 0,
                networkTxBytes: d.dbl("networkTxBytes") ?? 0,
                blockReadBytes: d.dbl("blockReadBytes") ?? 0,
                blockWriteBytes: d.dbl("blockWriteBytes") ?? 0,
                numProcesses: d.int("numProcesses") ?? 0
            )
        }
    }
}

// MARK: - 磁盘占用

struct DiskCategory: Hashable {
    var total: Int
    var active: Int
    var sizeBytes: Int64
    var reclaimableBytes: Int64
}

struct DiskUsage: Hashable {
    var containers: DiskCategory
    var images: DiskCategory
    var volumes: DiskCategory

    var totalSize: Int64 {
        containers.sizeBytes + images.sizeBytes + volumes.sizeBytes
    }

    var totalReclaimable: Int64 {
        containers.reclaimableBytes + images.reclaimableBytes + volumes.reclaimableBytes
    }

    static func parse(_ json: String) -> DiskUsage? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        func category(_ key: String) -> DiskCategory {
            let d = root.dict(key) ?? [:]
            return DiskCategory(
                total: d.int("total") ?? 0,
                active: d.int("active") ?? 0,
                sizeBytes: Int64(d.int("sizeInBytes") ?? 0),
                reclaimableBytes: Int64(d.int("reclaimable") ?? 0)
            )
        }

        return DiskUsage(
            containers: category("containers"),
            images: category("images"),
            volumes: category("volumes")
        )
    }
}

// MARK: - 系统状态

struct StatusField: Hashable, Identifiable {
    var key: String
    var value: String
    var id: String { key }
}

struct SystemStatus: Equatable {
    var running: Bool
    var serverVersion: String
    var clientVersion: String
    var hostOS: String
    var architecture: String
    var cpus: Int
    var containersTotal: Int
    var containersRunning: Int
    var imagesTotal: Int
    var rawFields: [StatusField]

    var cpuDisplay: String { "\(cpus)" }

    /// 服务未启动时的状态（此时 `container system status` 退出码为 1，提示信息在 stdout）
    static func notRunning(message: String) -> SystemStatus {
        SystemStatus(
            running: false,
            serverVersion: "—",
            clientVersion: "—",
            hostOS: "—",
            architecture: "—",
            cpus: 0,
            containersTotal: 0,
            containersRunning: 0,
            imagesTotal: 0,
            rawFields: [StatusField(key: "message", value: message)]
        )
    }

    /// 判断是否是「服务未运行」的提示文本
    static func isNotRunningMessage(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("not running") || t.contains("not registered")
    }

    static func parse(_ text: String) -> SystemStatus {
        var fields: [String: String] = [:]
        var ordered: [StatusField] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            guard !s.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            // 跳过表头
            if s.hasPrefix("FIELD") { continue }
            // 拆成 key + value（key 无空格，value 由空白分隔）
            let parts = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count >= 1 else { continue }
            let key = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            fields[key] = value
            ordered.append(StatusField(key: key, value: value))
        }

        return SystemStatus(
            running: (fields["status"] ?? "").lowercased() == "running",
            serverVersion: fields["server.version"] ?? "—",
            clientVersion: fields["client.version"] ?? "—",
            hostOS: fields["host.os"] ?? "—",
            architecture: fields["host.architecture"] ?? "—",
            cpus: Int(fields["host.cpus"] ?? "") ?? 0,
            containersTotal: Int(fields["containers.total"] ?? "") ?? 0,
            containersRunning: Int(fields["containers.running"] ?? "") ?? 0,
            imagesTotal: Int(fields["images.total"] ?? "") ?? 0,
            rawFields: ordered
        )
    }
}

// MARK: - 工具

enum Format {
    static func bytes(_ value: Int64) -> String {
        if value <= 0 { return "0 B" }
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.includesUnit = true
        return f.string(fromByteCount: value)
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return isoFractional.date(from: s) ?? iso.date(from: s)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// 把 docker.io/library/nginx:alpine 拆成 (docker.io/library/nginx, alpine)
    static func splitReference(_ reference: String) -> (String, String) {
        // 处理 registry:port/repo 的情况：最后一个冒号之后若不含 / 则视为 tag
        guard let colon = reference.lastIndex(of: ":") else { return (reference, "latest") }
        let after = reference[reference.index(after: colon)...]
        if after.contains("/") { return (reference, "latest") }
        return (String(reference[..<colon]), String(after))
    }
}

// MARK: - JSON 取值辅助

extension Dictionary where Key == String, Value == Any {
    func str(_ key: String) -> String? { self[key] as? String }

    func int(_ key: String) -> Int? {
        if let n = self[key] as? NSNumber { return n.intValue }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }

    func dbl(_ key: String) -> Double? {
        if let n = self[key] as? NSNumber { return n.doubleValue }
        if let s = self[key] as? String { return Double(s) }
        return nil
    }

    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }

    func arr(_ key: String) -> [[String: Any]]? { self[key] as? [[String: Any]] }

    func strArr(_ key: String) -> [String] { self[key] as? [String] ?? [] }
}
