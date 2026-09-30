import Foundation

/// 一次 CLI 调用的结果
struct CLIResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var ok: Bool { exitCode == 0 }

    /// 优先用 stderr 作为错误描述
    var errorMessage: String {
        let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { return e }
        let o = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return o.isEmpty ? "命令失败（退出码 \(exitCode)）" : o
    }

    var combinedOutput: String {
        var s = stdout
        if !stderr.isEmpty {
            if !s.isEmpty && !s.hasSuffix("\n") { s += "\n" }
            s += stderr
        }
        return s
    }
}

enum ContainerCLIError: LocalizedError {
    case notInstalled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "找不到 container 命令，请确认已安装 Apple container。"
        case .failed(let m):
            return m
        }
    }
}

/// 线程安全的 `container` 可执行文件定位与调用封装。
/// GUI App 的 PATH 通常不含 /usr/local/bin，所以这里始终用绝对路径。
final class ContainerCLI: @unchecked Sendable {
    static let shared = ContainerCLI()

    let executablePath: String

    private init() {
        let candidates = [
            "/usr/local/bin/container",
            "/opt/homebrew/bin/container",
            "/usr/bin/container",
        ]
        executablePath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/local/bin/container"
    }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    func makeProcess(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executablePath)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        return p
    }

    /// 同步执行并收集完整输出。请在后台线程调用。
    @discardableResult
    func run(_ args: [String]) throws -> CLIResult {
        guard isInstalled else { throw ContainerCLIError.notInstalled }

        let process = makeProcess(args)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()

        // 先启动读取，避免大输出把管道缓冲区写满造成死锁
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
        }
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
        }

        do {
            try process.run()
        } catch {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            group.wait()
            throw ContainerCLIError.failed("无法启动 container 命令：\(error.localizedDescription)")
        }

        group.wait()
        process.waitUntilExit()

        return CLIResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outBox.value, encoding: .utf8) ?? "",
            stderr: String(data: errBox.value, encoding: .utf8) ?? ""
        )
    }

    /// 执行并在失败时抛出
    @discardableResult
    func runChecked(_ args: [String]) throws -> CLIResult {
        let r = try run(args)
        guard r.ok else { throw ContainerCLIError.failed(r.errorMessage) }
        return r
    }
}

/// 简单的线程安全数据盒
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
