import Foundation

/// Lớp chặn cuối cùng: dù quy tắc có sai, đường dẫn không qua đây thì không bị xoá.
public struct PathGuard: Sendable {
    let allowedRoots: [String]
    let protectedExact: Set<String>
    let home: String

    /// Không bao giờ xoá bất cứ gì nằm trong các thư mục hoặc file này.
    static let protectedComponents: Set<String> = [
        ".ssh", ".gnupg", "Keychains", ".git", "oauth_creds.json", "google_accounts.json",
        "jetski-standalone-oauth-token",
    ]

    /// Lịch sử làm việc, tính từ home. Không quy tắc nào được phép xoá trong các vùng này.
    static let historyPaths = [
        ".claude/projects", ".claude/file-history", ".claude/history.jsonl", ".claude/todos", ".claude/plans",
        ".gemini/antigravity/conversations", ".gemini/antigravity/brain", ".gemini/antigravity/knowledge",
        ".gemini/antigravity/conversation_summaries.db", ".gemini/history", ".gemini/tmp",
        ".gemini/antigravity-ide",
        ".codex/sessions", ".codex/history.jsonl", ".codex/thread_history_1.sqlite",
        "Library/Application Support/Claude/vm_bundles",
        "Library/Application Support/Claude/claude-code-sessions",
        "Library/Application Support/Claude/local-agent-mode-sessions",
        "Library/Developer/Xcode/Archives", "Library/Developer/Xcode/DeviceLogs",
        ".Trash",
    ]

    public init(env: CleanEnvironment, projectRoots: [URL]) {
        self.init(home: env.home, tempRoot: env.tempRoot, projectRoots: projectRoots + [env.sharedTemp])
    }

    public init(home: URL, tempRoot: URL, projectRoots: [URL]) {
        let homePath = Self.normalized(home.path)
        self.home = homePath
        allowedRoots = ([homePath, Self.normalized(tempRoot.path)] + projectRoots.map { Self.normalized($0.path) })
        let keep = ["", "Library", "Library/Application Support", "Library/Caches", "Library/Developer",
                    "Library/Android", "Library/Android/sdk", "Desktop", "Documents", "Downloads", "Movies",
                    "Music", "Pictures", "Public", "Applications", ".claude", ".claude/projects", ".gemini",
                    ".gemini/antigravity", ".codex", ".config", ".local"]
        protectedExact = Set(keep.map { $0.isEmpty ? homePath : "\(homePath)/\($0)" }
            + projectRoots.map { Self.normalized($0.path) } + [Self.normalized(tempRoot.path)])
    }

    /// Gộp /var và /private/var, bỏ dấu / cuối để so sánh chuỗi tin cậy.
    public static func normalized(_ path: String) -> String {
        var result = (path as NSString).standardizingPath
        if result.hasPrefix("/private/") { result.removeFirst("/private".count) }
        return result
    }

    /// Media của agent là ngoại lệ duy nhất trong vùng lịch sử; văn bản hội thoại không lọt qua đây.
    static func isAgentMedia(_ path: String, home: String) -> Bool {
        for root in [".gemini/antigravity/brain/", ".gemini/antigravity-ide/brain/"] {
            let prefix = "\(home)/\(root)"
            guard path.hasPrefix(prefix) else { continue }
            let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
            guard parts.count >= 2, let name = parts.last else { return false }
            let extensionName = (name as NSString).pathExtension.lowercased()
            if parts.count == 2, parts[0] == "tempmediaStorage" { return true }
            if parts.count == 2 { return extensionName == "webp" || extensionName == "webm" }
            // Thư mục tạm còn chứa file dom_*.txt, ảnh chụp cấu trúc trang của cùng phiên.
            if parts.count == 3, parts[1] == ".tempmediaStorage" { return true }
            return parts.count == 4 && parts[1] == ".system_generated" && parts[2] == "click_feedback"
                && extensionName == "png"
        }
        return false
    }

    public func allows(_ url: URL) -> Bool {
        // Giải symlink của thư mục cha để symlink không dẫn ra ngoài vùng cho phép;
        // bản thân mục cuối nếu là symlink thì chỉ link bị xoá, không phải đích.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let path = Self.normalized(parent + "/" + url.lastPathComponent)

        guard path.split(separator: "/").count >= 3, !protectedExact.contains(path) else { return false }
        guard allowedRoots.contains(where: { path.hasPrefix($0 + "/") }) else { return false }
        if !Self.protectedComponents.isDisjoint(with: path.split(separator: "/").map(String.init)) { return false }
        if Self.isAgentMedia(path, home: home) { return true }
        if Self.historyPaths.contains(where: { path == "\(home)/\($0)" || path.hasPrefix("\(home)/\($0)/") }) { return false }
        if path.contains("/User/workspaceStorage") || path.contains("/User/History") { return false }
        return true
    }
}
