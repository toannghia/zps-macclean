import Foundation

public struct Cleaner: Sendable {
    let env: CleanEnvironment
    let guardrail: PathGuard
    let logURL: URL?

    public init(env: CleanEnvironment, projectRoots: [URL], logURL: URL? = nil) {
        self.env = env
        self.logURL = logURL
        guardrail = PathGuard(env: env, projectRoots: projectRoots)
    }

    public func clean(_ items: [CleanItem], progress: @escaping @Sendable (WorkProgress) -> Void = { _ in }) -> CleanReport {
        var report = CleanReport()
        let volumes = Self.volumes(for: items, home: env.home)
        let before = volumes.map(Self.freeBytes)
        // Kiểm tra lại app đang chạy vì người dùng có thể mở app sau lần quét.
        let commands = env.runningCommands()
        guard let open = env.openPaths() else {
            report.failures.append("Không kiểm tra được file đang mở nên chưa xoá gì.")
            return report
        }

        for (index, item) in items.enumerated() {
            progress(WorkProgress(fraction: Double(index) / Double(items.count),
                                  phase: "Đang dọn (\(index + 1)/\(items.count))", detail: item.title,
                                  foundBytes: report.estimatedBytes))
            let running = JunkScanner.running(item.blockHints, commands: commands)
            if !running.isEmpty {
                report.failures.append("\(item.title): cần đóng \(running.joined(separator: ", "))")
                continue
            }
            var failed = false
            switch item.action {
            case .delete(let urls):
                for url in urls {
                    if open.contains(PathGuard.normalized(url.path)) {
                        report.failures.append("\(url.lastPathComponent): đang được dùng, đã giữ lại")
                        failed = true
                    } else if !perform(url, item: item, report: &report) {
                        failed = true
                    }
                }
            case .command(let executable, let arguments):
                var message = ""
                if Shell.run(executable, arguments, timeout: 900, errors: &message) == nil {
                    report.failures.append("\(item.title): \(message.prefix(200))")
                    failed = true
                }
                log("command \(executable) \(arguments.joined(separator: " ")) ok=\(!failed)")
            }
            if !failed {
                report.cleanedCount += 1
                report.estimatedBytes += item.size
            }
        }

        let after = volumes.map(Self.freeBytes)
        report.actualFreedBytes = zip(before, after).reduce(0) { $0 + max(0, $1.1 - $1.0) }
        report.freedByDisk = zip(volumes, zip(before, after)).map { volume, change in
            DiskInfo(name: Self.diskName(volume, home: env.home), free: max(0, change.1 - change.0), total: 0)
        }
        return report
    }

    private func perform(_ url: URL, item: CleanItem, report: inout CleanReport) -> Bool {
        guard guardrail.allows(url) else {
            report.failures.append("\(item.title): từ chối xoá \(url.path)")
            log("refused \(url.path)")
            return false
        }
        do {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                // removeItem có thể báo lỗi dù thư mục đã mất, nên chỉ thử lại khi nó còn tồn tại.
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            log("deleted \(url.path)")
            return true
        } catch {
            report.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            log("failed \(url.path): \(error.localizedDescription)")
            return false
        }
    }

    private func log(_ line: String) {
        guard let logURL else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }

    static func volumes(for items: [CleanItem], home: URL) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for url in [home] + items.flatMap(\.action.urls) {
            let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? home
            if seen.insert(volume).inserted { result.append(volume) }
        }
        return result
    }

    public static func diskName(_ volume: URL, home: URL) -> String {
        let homeVolume = (try? home.resourceValues(forKeys: [.volumeURLKey]))?.volume
        if volume == homeVolume { return "Ổ hệ thống" }
        return (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            ?? volume.lastPathComponent
    }

    /// Dung lượng của ổ hệ thống và các ổ chứa thư mục dự án.
    public static func disks(home: URL, projectRoots: [URL]) -> [DiskInfo] {
        var seen = Set<URL>()
        return ([home] + projectRoots).compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeTotalCapacityKey]),
                  let volume = values.volume, seen.insert(volume).inserted else { return nil }
            return DiskInfo(name: diskName(volume, home: home), free: freeBytes(volume),
                            total: Int64(values.volumeTotalCapacity ?? 0))
        }
    }

    public static func freeBytes(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }
}
