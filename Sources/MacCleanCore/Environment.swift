import Foundation

/// Các hệ phụ thuộc vào máy thật, tách ra để test chạy trên cây thư mục giả.
public struct CleanEnvironment: Sendable {
    public let home: URL
    /// Thư mục cha của $TMPDIR, chứa các nhánh T, C, X.
    public let tempRoot: URL
    /// Thư mục /tmp dùng chung của hệ thống.
    public let sharedTemp: URL
    public var runningCommands: @Sendable () -> [String]
    /// nil nghĩa là không xác định được, khi đó không được phép xoá gì.
    public var openPaths: @Sendable () -> Set<String>?
    public var docker: @Sendable () -> DockerUsage?

    public init(home: URL, tempRoot: URL, sharedTemp: URL? = nil,
                runningCommands: @escaping @Sendable () -> [String] = { [] },
                openPaths: @escaping @Sendable () -> Set<String>? = { [] },
                docker: @escaping @Sendable () -> DockerUsage? = { nil }) {
        self.home = home
        self.tempRoot = tempRoot
        self.sharedTemp = sharedTemp ?? tempRoot.appendingPathComponent("shared")
        self.runningCommands = runningCommands
        self.openPaths = openPaths
        self.docker = docker
    }

    public static var live: CleanEnvironment {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        return CleanEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser,
            tempRoot: tmp.deletingLastPathComponent(),
            sharedTemp: URL(fileURLWithPath: "/private/tmp"),
            runningCommands: {
                Shell.run("/bin/ps", ["-axww", "-o", "command="], timeout: 10)?
                    .split(separator: "\n").map(String.init) ?? []
            },
            openPaths: {
                // Khai báo cả các thư mục cha để tra cứu "có file nào bên trong đang mở" trong O(1).
                guard let out = Shell.run("/usr/sbin/lsof", ["-nP", "-Fn"], timeout: 45) else { return nil }
                var result = Set<String>()
                for line in out.split(separator: "\n") where line.hasPrefix("n/") {
                    var path = PathGuard.normalized(String(line.dropFirst()))
                    while path.count > 1, result.insert(path).inserted {
                        path = (path as NSString).deletingLastPathComponent
                    }
                }
                return result
            },
            docker: { DockerUsage.probe() }
        )
    }
}

public enum Shell {
    /// Chạy lệnh và trả stdout; nil nếu lỗi hoặc quá thời gian.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        run(executable, arguments, timeout: timeout, errors: nil)
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                    errors: UnsafeMutablePointer<String>?) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            errors?.pointee = error.localizedDescription
            return nil
        }
        let killer = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        // Đọc hai pipe song song để tiến trình con không treo khi đầy buffer.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        killer.cancel()

        guard process.terminationStatus == 0, process.terminationReason == .exit else {
            errors?.pointee = String(decoding: errData, as: UTF8.self)
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct DockerUsage: Sendable {
    public let executable: String
    public let buildCacheReclaimable: Int64

    public init(executable: String, buildCacheReclaimable: Int64) {
        self.executable = executable
        self.buildCacheReclaimable = buildCacheReclaimable
    }

    static func probe() -> DockerUsage? {
        let candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
        guard let docker = candidates.first(where: FileManager.default.isExecutableFile) else { return nil }
        guard let out = Shell.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 30) else { return nil }
        return parse(out, executable: docker)
    }

    public static func parse(_ output: String, executable: String) -> DockerUsage? {
        var cache: Int64 = 0
        for line in output.split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = json["Type"] as? String,
                  let reclaimable = json["Reclaimable"] as? String else { continue }
            if type == "Build Cache" { cache = parseSize(reclaimable) }
        }
        return DockerUsage(executable: executable, buildCacheReclaimable: cache)
    }

    /// Đọc chuỗi kiểu "33.62GB (68%)".
    static func parseSize(_ text: String) -> Int64 {
        let token = text.split(separator: " ").first.map(String.init) ?? ""
        let digits = token.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return 0 }
        let units: [String: Double] = ["B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12]
        return Int64(value * (units[String(token.dropFirst(digits.count)).uppercased()] ?? 1))
    }
}
