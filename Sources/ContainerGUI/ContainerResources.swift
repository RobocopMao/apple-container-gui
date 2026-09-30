import Foundation

/// 读写某个容器创建时固化的资源限制（CPU 核数 / 内存）。
///
/// Apple container 没有修改已建容器的命令，参数在 create 时就写进了容器目录下的
/// `config.json`。这里直接改那份配置，再靠「停止 → 改 → 启动」让它生效。
///
/// 实测结论（本机 container 1.5.0）：
/// - 改完 config.json 后**只需重启该容器**，新值就进 cgroup 生效（cpu.max / memory.max）。
/// - `container ls` / `inspect` 读的是 apiserver 的缓存，会**一直显示旧值**，
///   只有重启整个 container 服务才会刷新 —— 所以界面上的数字要自己按新值渲染，
///   不能指望 ls 立刻跟上。
enum ContainerResources {
    struct Limits: Equatable {
        var cpus: Int
        var memoryMB: Int

        var memoryBytes: Int64 { Int64(memoryMB) * 1024 * 1024 }
    }

    enum ResourceError: LocalizedError {
        case containerDirMissing(String)
        case configUnreadable(String)
        case configMalformed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .containerDirMissing(let id):
                return "找不到容器「\(id)」的配置目录。"
            case .configUnreadable(let path):
                return "读不到配置文件：\(path)"
            case .configMalformed:
                return "配置文件格式异常，未做修改。"
            case .writeFailed(let msg):
                return "写入配置失败：\(msg)"
            }
        }
    }

    /// 容器配置目录：~/Library/Application Support/com.apple.container/containers/<id>/
    static func configURL(for id: String) -> URL {
        let base = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.container/containers", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        return base.appendingPathComponent("config.json")
    }

    /// 读当前限制。读的是磁盘上的真值，不受 apiserver 缓存影响。
    static func read(_ id: String) throws -> Limits {
        let url = configURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ResourceError.configUnreadable(url.path)
        }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let res = obj["resources"] as? [String: Any] else {
            throw ResourceError.configMalformed
        }
        let cpus = (res["cpus"] as? NSNumber)?.intValue ?? 0
        let bytes = (res["memoryInBytes"] as? NSNumber)?.int64Value ?? 0
        return Limits(cpus: cpus, memoryMB: Int(bytes / (1024 * 1024)))
    }

    /// 只改 resources 两个字段，其余原样保留（端口、挂载、环境变量等一概不动）。
    static func write(_ id: String, limits: Limits) throws {
        let url = configURL(for: id)
        guard let data = try? Data(contentsOf: url),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var res = obj["resources"] as? [String: Any] else {
            throw ResourceError.configMalformed
        }

        res["cpus"] = limits.cpus
        res["memoryInBytes"] = limits.memoryBytes
        obj["resources"] = res

        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: []) else {
            throw ResourceError.configMalformed
        }
        do {
            try out.write(to: url, options: .atomic)
        } catch {
            throw ResourceError.writeFailed(error.localizedDescription)
        }
    }
}
