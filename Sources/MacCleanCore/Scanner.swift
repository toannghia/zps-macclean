import Foundation

public enum ScanError: Error {
    case openFilesUnknown
}

public struct JunkScanner: Sendable {
    /// Dữ liệu vừa được ghi trong khoảng này coi như đang dùng, dù không có file nào đang mở.
    static let quietPeriod: TimeInterval = 2 * 3600

    let env: CleanEnvironment

    public init(env: CleanEnvironment) {
        self.env = env
    }

    public func scan(options: ScanOptions, rules: [Rule] = RuleBook.all,
                     progress: @escaping @Sendable (WorkProgress) -> Void = { _ in }) throws -> [CleanItem] {
        let commands = env.runningCommands()
        progress(WorkProgress(fraction: 0.02, phase: "Kiểm tra việc đang chạy", detail: "App đang mở và file đang dùng"))
        guard let open = env.openPaths() else { throw ScanError.openFilesUnknown }

        let lock = NSLock()
        var items: [CleanItem] = []
        var done = 0
        var found: Int64 = 0
        DispatchQueue.concurrentPerform(iterations: rules.count) { index in
            let item = evaluate(rules[index], options: options, commands: commands, open: open)
            lock.lock()
            if let item {
                items.append(item)
                found += item.size
            }
            done += 1
            let update = WorkProgress(fraction: 0.05 + 0.4 * Double(done) / Double(rules.count),
                                      phase: "Đo cache và công cụ (\(done)/\(rules.count))",
                                      detail: rules[index].title, foundBytes: found)
            lock.unlock()
            progress(update)
        }

        let base = found
        items += ProjectScanner().scan(options: options, open: open) { update in
            var update = update
            update.fraction = 0.45 + 0.5 * update.fraction
            update.foundBytes += base
            progress(update)
        }
        found = items.reduce(0) { $0 + $1.size }

        progress(WorkProgress(fraction: 0.96, phase: "Kiểm tra Docker", detail: "docker system df", foundBytes: found))
        if let docker = env.docker() {
            items += Self.dockerItems(docker, commands: commands)
        }
        return items.filter { $0.size > 0 }.sorted { $0.size > $1.size }
    }

    func evaluate(_ rule: Rule, options: ScanOptions, commands: [String], open: Set<String>) -> CleanItem? {
        let ageLimit: Int? = {
            switch rule.age {
            case .any: return nil
            case .days(let days): return days
            }
        }()
        let cutoff = ageLimit.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        let quietCutoff = Date().addingTimeInterval(-Self.quietPeriod)

        let usedImages = rule.keepUsedSystemImages ? usedSystemImages() : []
        // Không đọc được cấu hình máy ảo thì không kết luận image nào là thừa.
        if rule.keepUsedSystemImages, usedImages.isEmpty { return nil }
        var candidates: [(url: URL, stats: DirectoryStats)] = []
        var inUse = 0
        for pattern in rule.patterns {
            let matches = Glob.expand(pattern, env: env)
            let outdated = rule.keepHighestVersion
                ? ExtensionVersions.outdated(matches.map(\.lastPathComponent)) : nil
            for url in matches {
                if rule.exclude.contains(url.lastPathComponent) { continue }
                if rule.keepUsedSystemImages, usedImages.contains(where: { $0.hasSuffix(Self.imageKey(url)) }) {
                    continue
                }
                if rule.keepReferenced, Self.isReferenced(url) {
                    inUse += 1
                    continue
                }
                if let outdated, !outdated.contains(url.lastPathComponent) { continue }
                if open.contains(PathGuard.normalized(url.path)) {
                    inUse += 1
                    continue
                }
                let stats = DirectoryStats.measure(url)
                if stats.newest > quietCutoff {
                    inUse += 1
                    continue
                }
                if let cutoff, stats.newest > cutoff { continue }
                candidates.append((url, stats))
            }
        }
        if rule.keepNewest > 0 {
            candidates = Array(candidates.sorted { $0.stats.newest > $1.stats.newest }.dropFirst(rule.keepNewest))
        }
        guard !candidates.isEmpty else { return nil }

        let urls = candidates.map(\.url)
        var note = rule.note
        if let ageLimit { note += " Chỉ gồm dữ liệu cũ hơn \(ageLimit) ngày." }
        return CleanItem(
            id: rule.id, title: rule.title, note: note, category: rule.category, risk: rule.risk,
            action: .delete(urls),
            size: rule.sharesStorage ? candidates.map(\.stats.size).max() ?? 0
                                     : candidates.reduce(0) { $0 + $1.stats.size },
            blockedBy: Self.running(rule.blockers, commands: commands),
            blockHints: rule.blockers, skippedInUse: inUse
        )
    }

    /// Dạng `android-36/google_apis_playstore` của một thư mục system image.
    static func imageKey(_ url: URL) -> String {
        "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
    }

    /// Các image máy ảo đang trỏ tới, đọc từ `image.sysdir.1` trong config.ini.
    func usedSystemImages() -> [String] {
        Glob.expand(".android/avd/*.avd/config.ini", env: env).compactMap { config in
            guard let text = try? String(contentsOf: config, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("image.sysdir.1") }),
                  let value = line.split(separator: "=").last else { return nil }
            let parts = value.split(separator: "/").map(String.init)
            guard parts.count >= 3 else { return nil }
            return parts[1] + "/" + parts[2]
        }
    }

    /// File có được tài liệu nằm cùng thư mục nhắc đến tên hay không.
    static func isReferenced(_ url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { name in
            guard name.hasSuffix(".md") || name.contains(".md.resolved") else { return false }
            let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            return text?.contains(url.lastPathComponent) ?? false
        }
    }

    public static func running(_ hints: [AppHint], commands: [String]) -> [String] {
        hints.filter { hint in commands.contains { $0.contains(hint.match) } }.map(\.name)
    }

    /// Không prune khi đang có lệnh build chạy.
    static let dockerBusy = [AppHint("docker build", match: "docker build"), AppHint("docker buildx", match: "buildx"),
                             AppHint("docker compose build", match: "compose build")]

    static func dockerItems(_ docker: DockerUsage, commands: [String] = []) -> [CleanItem] {
        [
            CleanItem(id: "docker.builder", title: "Docker: build cache",
                      note: "Lần build image sau sẽ chậm hơn. Dung lượng trả về macOS dần khi Docker thu gọn ổ ảo.",
                      category: .docker, risk: .review,
                      action: .command(executable: docker.executable, arguments: ["builder", "prune", "-af"]),
                      size: docker.buildCacheReclaimable, blockedBy: running(dockerBusy, commands: commands),
                      blockHints: dockerBusy),
        ]
    }
}

public struct DirectoryStats: Sendable {
    public var size: Int64 = 0
    public var newest = Date.distantPast

    /// Đo dung lượng thực cấp phát và lần sửa mới nhất; không đi theo symlink.
    public static func measure(_ url: URL) -> DirectoryStats {
        var stats = DirectoryStats()
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isDirectoryKey]
        func add(_ values: URLResourceValues?) {
            stats.size += Int64(values?.totalFileAllocatedSize ?? 0)
            if let date = values?.contentModificationDate, date > stats.newest { stats.newest = date }
        }
        add(try? url.resourceValues(forKeys: keys))
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true,
              let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                          options: [], errorHandler: { _, _ in true }) else {
            return stats
        }
        for case let child as URL in walker {
            add(try? child.resourceValues(forKeys: keys))
        }
        return stats
    }
}

enum Glob {
    static let ignored: Set<String> = [".DS_Store", ".localized", "CACHEDIR.TAG"]

    static func expand(_ pattern: String, env: CleanEnvironment) -> [URL] {
        let (base, relative): (URL, String)
        if pattern.hasPrefix("$TEMP/") {
            (base, relative) = (env.tempRoot, String(pattern.dropFirst("$TEMP/".count)))
        } else if pattern.hasPrefix("$SHARED/") {
            (base, relative) = (env.sharedTemp, String(pattern.dropFirst("$SHARED/".count)))
        } else {
            (base, relative) = (env.home, pattern)
        }
        var current = [base]
        let parts = relative.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            current = current.flatMap { step($0, part: part, isLast: isLast) }
        }
        return current
    }

    private static func step(_ directory: URL, part: String, isLast: Bool) -> [URL] {
        let fm = FileManager.default
        if !part.contains("*") {
            let url = directory.appendingPathComponent(part)
            return exists(url, followable: !isLast) ? [url] : []
        }
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { !ignored.contains($0) && fnmatch(part, $0, FNM_PERIOD) == 0 }
            .map { directory.appendingPathComponent($0) }
            .filter { exists($0, followable: !isLast) }
    }

    /// Thư mục trung gian là symlink thì dừng, để quy tắc không lan ra ngoài cây đã dự kiến.
    private static func exists(_ url: URL, followable mustBeRealDirectory: Bool) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return !mustBeRealDirectory || (info.st_mode & S_IFMT) == S_IFDIR
    }
}

/// Tìm thư mục tái tạo được trong các dự án lâu không đụng tới.
struct ProjectScanner {
    struct Artifact {
        let name: String
        let markers: [String]
    }

    static let artifacts = [
        Artifact(name: "node_modules", markers: ["package.json"]),
        Artifact(name: ".next", markers: ["package.json"]),
        Artifact(name: ".nuxt", markers: ["package.json"]),
        Artifact(name: ".svelte-kit", markers: ["package.json"]),
        Artifact(name: ".turbo", markers: ["package.json"]),
        Artifact(name: ".angular", markers: ["angular.json"]),
        Artifact(name: ".dart_tool", markers: ["pubspec.yaml"]),
        Artifact(name: "build", markers: ["pubspec.yaml"]),
        Artifact(name: "Pods", markers: ["Podfile"]),
        Artifact(name: "target", markers: ["Cargo.toml", "pom.xml"]),
        Artifact(name: ".gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]),
        Artifact(name: ".venv", markers: ["pyproject.toml", "requirements.txt"]),
    ]

    static let skippedDirectories: Set<String> = ["Library", ".git", "Applications", ".Trash", ".Trashes"]
    static let maxDepth = 8
    static let minimumSize: Int64 = 10 * 1_000_000

    func scan(options: ScanOptions, open: Set<String>,
              progress: @escaping @Sendable (WorkProgress) -> Void = { _ in }) -> [CleanItem] {
        var found: [(project: URL, artifacts: [URL])] = []
        for root in options.projectRoots {
            progress(WorkProgress(fraction: 0, phase: "Tìm dự án", detail: root.path))
            walk(root, depth: 0, into: &found)
        }
        let cutoff = Date().addingTimeInterval(-Double(options.retentionDays) * 86_400)

        let lock = NSLock()
        var items: [CleanItem] = []
        var done = 0
        var bytes: Int64 = 0
        let total = found.count
        @Sendable func report(_ project: URL) {
            lock.lock()
            done += 1
            let update = WorkProgress(fraction: Double(done) / Double(total), phase: "Quét dự án (\(done)/\(total))",
                                      detail: project.path, foundBytes: bytes)
            lock.unlock()
            progress(update)
        }
        DispatchQueue.concurrentPerform(iterations: found.count) { index in
            let (project, artifacts) = found[index]
            defer { report(project) }
            // Có tiến trình làm việc bên trong dự án (dev server, terminal) thì bỏ qua.
            guard !open.contains(PathGuard.normalized(project.path)),
                  lastActivity(of: project, artifacts: artifacts) < cutoff else { return }
            let size = artifacts.reduce(Int64(0)) { $0 + DirectoryStats.measure($1).size }
            guard size >= Self.minimumSize else { return }
            let names = artifacts.map(\.lastPathComponent).joined(separator: ", ")
            let item = CleanItem(
                id: "project:\(project.path)", title: project.lastPathComponent,
                note: "\(names) — \(project.path)", category: .projects, risk: .review,
                action: .delete(artifacts), size: size)
            lock.lock()
            items.append(item)
            bytes += size
            lock.unlock()
        }
        return items
    }

    private func walk(_ directory: URL, depth: Int, into found: inout [(project: URL, artifacts: [URL])]) {
        guard depth <= Self.maxDepth,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let present = Set(names)
        let artifacts = Self.artifacts
            .filter { present.contains($0.name) && !present.isDisjoint(with: $0.markers) }
            .map { directory.appendingPathComponent($0.name) }
        if !artifacts.isEmpty { found.append((directory, artifacts)) }

        let artifactNames = Set(artifacts.map(\.lastPathComponent))
        for name in names where !name.hasPrefix(".") && !artifactNames.contains(name)
            && !Self.skippedDirectories.contains(name) && !name.hasSuffix(".app") {
            let url = directory.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            walk(url, depth: depth + 1, into: &found)
        }
    }

    /// Thời điểm làm việc gần nhất, không tính thư mục rác và không quét sâu toàn cây mã nguồn.
    private func lastActivity(of project: URL, artifacts: [URL]) -> Date {
        let excluded = Set(artifacts.map(\.lastPathComponent))
        let fm = FileManager.default
        var entries = ((try? fm.contentsOfDirectory(atPath: project.path)) ?? [])
            .filter { !excluded.contains($0) }
            .map { project.appendingPathComponent($0) }
        entries += [".git/index", ".git/HEAD", ".git/logs/HEAD"].map { project.appendingPathComponent($0) }
        return entries.compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max() ?? .distantPast
    }
}
