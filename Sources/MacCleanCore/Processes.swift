import Darwin
import Foundation

public struct ProcessEntry: Identifiable, Sendable {
    public let pid: Int32
    public let parent: Int32
    public let user: String
    public let cpu: Double
    public let memory: Int64
    public let path: String
    public let command: String
    public var id: Int32 { pid }

    public var name: String { (path as NSString).lastPathComponent }
}

/// Các tiến trình của một ứng dụng, hoặc cùng tên nếu không thuộc app nào.
public struct ProcessGroup: Identifiable, Sendable {
    public let name: String
    /// Đường dẫn .app nếu nhóm thuộc một ứng dụng.
    public let bundlePath: String?
    public let processes: [ProcessEntry]
    /// Lý do không cho tắt; nil nghĩa là được tắt.
    public let protection: String?
    /// Cảnh báo riêng khi tắt, ví dụ làm dừng công việc đang chạy.
    public let warning: String?

    public var id: String { "\(bundlePath ?? name)|\(protection == nil ? "free" : "locked")" }
    public var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
    public var memory: Int64 { processes.reduce(0) { $0 + $1.memory } }
}

public struct SystemUsage: Sendable {
    public var memoryUsed: Int64 = 0
    public var memoryTotal: Int64 = 0
    public var cpuPercent: Double = 0

    public init() {}
}

public enum ProcessMonitor {
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/"]
    /// App người dùng mở được dù nằm trong /System, như Preview, Safari, Mail.
    static let userAppMarkers = ["/System/Applications/", "/System/Cryptexes/App/System/Applications/",
                                 "/Cryptexes/App/System/Applications/"]

    static let warnings: [(match: String, text: String)] = [
        ("Claude", "Tắt Claude sẽ dừng mọi phiên AI đang chạy, kể cả phiên đang làm việc với bạn."),
        ("Antigravity", "Agent đang chạy trong Antigravity sẽ dừng giữa chừng."),
        ("Docker", "Mọi container đang chạy sẽ dừng theo."),
        ("Xcode", "Bản build đang chạy sẽ bị huỷ."),
        ("postgres", "Database sẽ dừng, các app đang kết nối sẽ lỗi."),
        ("node", "Có thể là dev server hoặc công cụ đang chạy. Mở xem chi tiết trước khi tắt."),
        ("java", "Có thể là Gradle hoặc server đang chạy. Mở xem chi tiết trước khi tắt."),
    ]

    /// Đọc danh sách tiến trình. `ps` cho CPU, còn RAM ưu tiên số đo giống Activity Monitor.
    public static func snapshot() -> [ProcessEntry]? {
        guard let table = Shell.run("/bin/ps", ["-axww", "-o", "pid=,ppid=,user=,pcpu=,rss=,comm="], timeout: 10),
              let commands = Shell.run("/bin/ps", ["-axww", "-o", "pid=,command="], timeout: 10) else { return nil }
        return parse(table: table, commands: commands, footprint: memoryFootprint, realPath: currentPath)
    }

    public static func parse(table: String, commands: String,
                             footprint: (Int32) -> Int64? = { _ in nil },
                             realPath: (Int32) -> String? = { _ in nil }) -> [ProcessEntry] {
        var fullCommands: [Int32: String] = [:]
        for line in commands.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, let pid = Int32(parts[0]) { fullCommands[pid] = String(parts[1]) }
        }
        return table.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count == 6, let pid = Int32(parts[0]), let parent = Int32(parts[1]),
                  let cpu = Double(parts[3].replacingOccurrences(of: ",", with: ".")),
                  let rss = Int64(parts[4]) else { return nil }
            // Tiến trình như next-server tự đổi tên, khi đó hỏi hệ thống đường dẫn thật.
            let listed = String(parts[5])
            let path = listed.hasPrefix("/") ? listed : realPath(pid) ?? listed
            return ProcessEntry(pid: pid, parent: parent, user: String(parts[2]), cpu: cpu,
                                memory: footprint(pid) ?? rss * 1024, path: path,
                                command: fullCommands[pid] ?? String(parts[5]))
        }
    }

    /// Lý do một tiến trình không được tắt.
    public static func protection(of entry: ProcessEntry, currentUser: String, currentPID: Int32) -> String? {
        if entry.pid <= 1 { return "Tiến trình lõi của macOS" }
        if entry.pid == currentPID || entry.path.contains("/ZPS MacClean.app/") { return "Chính là ZPS MacClean" }
        if entry.user != currentUser { return "Thuộc hệ thống hoặc người dùng khác" }
        if !entry.path.hasPrefix("/") { return "Không xác định được chương trình" }
        if userAppMarkers.contains(where: entry.path.contains) { return nil }
        if systemPrefixes.contains(where: entry.path.hasPrefix) { return "Tiến trình hệ thống macOS" }
        return nil
    }

    public static func group(_ entries: [ProcessEntry], currentUser: String = NSUserName(),
                             currentPID: Int32 = getpid()) -> [ProcessGroup] {
        var buckets: [String: [ProcessEntry]] = [:]
        var bundles: [String: String] = [:]
        for entry in entries {
            let locked = protection(of: entry, currentUser: currentUser, currentPID: currentPID) != nil
            let bundle = bundlePath(of: entry.path)
            let key = (bundle ?? entry.name) + (locked ? "\u{0}locked" : "")
            buckets[key, default: []].append(entry)
            if let bundle { bundles[key] = bundle }
        }
        return buckets.map { key, processes in
            let bundle = bundles[key]
            let name = bundle.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
                ?? processes[0].name
            let locked = processes.lazy
                .compactMap { protection(of: $0, currentUser: currentUser, currentPID: currentPID) }.first
            return ProcessGroup(name: name, bundlePath: bundle, processes: processes, protection: locked,
                                warning: warnings.first { name.localizedCaseInsensitiveContains($0.match) }?.text)
        }
    }

    /// Lọc nhóm hiển thị: nhóm có khoá là tiến trình hệ thống, chỉ hiện khi người dùng bật.
    public static func visible(_ groups: [ProcessGroup], includeSystem: Bool, query: String) -> [ProcessGroup] {
        groups.filter { group in
            guard includeSystem || group.protection == nil else { return false }
            return query.isEmpty || group.name.localizedCaseInsensitiveContains(query)
                || group.processes.contains { String($0.pid) == query }
        }
    }

    /// Lấy .app ngoài cùng, để helper lồng bên trong về chung với app chính.
    static func bundlePath(of path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.upperBound].dropLast())
    }

    public static func systemUsage(cpuTotal: Double) -> SystemUsage {
        var usage = SystemUsage()
        usage.memoryTotal = Int64(ProcessInfo.processInfo.physicalMemory)
        usage.cpuPercent = min(100, cpuTotal / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)))
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let pages = Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
            usage.memoryUsed = pages * Int64(vm_kernel_page_size)
        }
        return usage
    }

    static func memoryFootprint(_ pid: Int32) -> Int64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? Int64(info.ri_phys_footprint) : nil
    }

    static func currentPath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// Gửi tín hiệu tắt. Trả về thông báo lỗi, hoặc nil nếu đã gửi được.
    public static func stop(_ entry: ProcessEntry, force: Bool, currentUser: String = NSUserName(),
                            currentPID: Int32 = getpid()) -> String? {
        if let reason = protection(of: entry, currentUser: currentUser, currentPID: currentPID) {
            return "\(entry.name): \(reason)"
        }
        // PID có thể đã được cấp lại cho chương trình khác kể từ lần đọc trước.
        guard let current = currentPath(of: entry.pid) else { return nil }
        guard PathGuard.normalized(current) == PathGuard.normalized(entry.path) else {
            return "\(entry.name): tiến trình đã thay đổi, chưa tắt"
        }
        if kill(entry.pid, force ? SIGKILL : SIGTERM) == 0 || errno == ESRCH { return nil }
        return "\(entry.name): \(String(cString: strerror(errno)))"
    }
}
