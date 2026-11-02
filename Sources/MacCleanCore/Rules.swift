import Foundation

public struct Rule: Sendable {
    public enum Age: Sendable {
        case any
        case days(Int)
    }

    public var id: String
    public var title: String
    public var note: String
    public var category: CleanCategory
    public var risk: Risk
    /// Tương đối so với home; `*` khớp một cấp thư mục; `$TEMP/` là gốc thư mục tạm.
    public var patterns: [String]
    public var age: Age = .any
    public var keepNewest = 0
    public var keepHighestVersion = false
    public var exclude: Set<String> = []
    /// Giữ file còn được tài liệu cùng thư mục nhắc tới, ví dụ video nhúng trong walkthrough.md.
    public var keepReferenced = false
    /// Các mục là APFS clone dùng chung dữ liệu, cộng dồn sẽ phóng đại nên chỉ tính bản lớn nhất.
    public var sharesStorage = false
    /// Giữ system image Android còn được máy ảo nào đó sử dụng.
    public var keepUsedSystemImages = false
    public var blockers: [AppHint] = []
}

enum Apps {
    static let claude = AppHint("Claude", match: "/Claude.app/")
    static let antigravity = AppHint("Antigravity", match: "/Antigravity.app/")
    static let antigravityIDE = AppHint("Antigravity IDE", match: "/Antigravity IDE.app/")
    static let antigravityBrowser = AppHint("Trình duyệt Antigravity", match: "antigravity-browser-profile")
    static let vscode = AppHint("VS Code", match: "/Visual Studio Code.app/")
    static let cursor = AppHint("Cursor", match: "/Cursor.app/")
    static let windsurf = AppHint("Windsurf", match: "/Windsurf.app/")
    static let xcode = AppHint("Xcode", match: "/Xcode.app/Contents/MacOS/Xcode")
    static let chrome = AppHint("Google Chrome", match: "/Google Chrome.app/")
    static let cocCoc = AppHint("Cốc Cốc", match: "/CocCoc.app/")
    static let emulator = AppHint("Android Emulator", match: "qemu-system")
    static let dingTalk = AppHint("DingTalk", match: "/DingTalk.app/")
    static let canva = AppHint("Canva", match: "/Canva.app/")
    static let zalo = AppHint("Zalo", match: "/Zalo.app/")
}

public enum RuleBook {
    private static let electronCaches = ["Cache", "Code Cache", "GPUCache", "DawnWebGPUCache", "DawnGraphiteCache",
                                         "GraphiteDawnCache", "Shared Dictionary", "CachedData", "Crashpad", "logs"]

    private static func ide(_ name: String, folder: String, extensions: String, app: AppHint, category: CleanCategory) -> [Rule] {
        let support = "Library/Application Support/\(folder)"
        var rules = [
            Rule(id: "\(folder).cache", title: "\(name): cache & log",
                 note: "Cache Electron, log và crash dump. App tự tạo lại.",
                 category: category, risk: .safe,
                 patterns: electronCaches.map { "\(support)/\($0)" }, blockers: [app]),
            Rule(id: "\(folder).vsix", title: "\(name): gói extension đã tải",
                 note: "Bản cài .vsix lưu lại sau khi cài extension.",
                 category: category, risk: .safe,
                 patterns: ["\(support)/CachedExtensionVSIXs"], blockers: [app]),
        ]
        if !extensions.isEmpty {
            rules.append(Rule(id: "\(folder).oldext", title: "\(name): extension bản cũ",
                              note: "Giữ lại bản mới nhất của mỗi extension, xoá các bản cũ còn sót.",
                              category: category, risk: .review,
                              patterns: ["\(extensions)/*"], keepHighestVersion: true, blockers: [app]))
        }
        return rules
    }

    public static let all: [Rule] = browsers + aiTools + editors + mobile + packages + temp

    static let browsers: [Rule] = [
        Rule(id: "browser.clones", title: "Bản sao code-sign của trình duyệt",
             note: "Chromium tạo một bản sao mỗi lần chạy nhưng không dọn lại. Bản đang chạy được giữ nguyên. Các bản dùng chung dữ liệu nên số hiển thị chỉ tính một bản; dung lượng thật có thể cao hơn.",
             category: .browsers, risk: .safe,
             patterns: ["$TEMP/X/*.code_sign_clone/code_sign_clone.*"], sharesStorage: true),
        Rule(id: "browser.crx", title: "Trình duyệt: gói cập nhật đã tải",
             note: "Gói cài extension và thành phần trình duyệt giữ lại sau khi cập nhật.",
             category: .browsers, risk: .review,
             patterns: ["Library/Application Support/Google/Chrome/component_crx_cache",
                        "Library/Application Support/Google/Chrome/extensions_crx_cache",
                        "Library/Application Support/CocCoc/CocCocUpdater/crx_cache"],
             blockers: [Apps.chrome, Apps.cocCoc]),
        Rule(id: "browser.chromecache", title: "Google Chrome: cache",
             note: "Cache trang web. Không ảnh hưởng mật khẩu, lịch sử hay tab.",
             category: .browsers, risk: .review,
             patterns: ["Library/Caches/Google/Chrome/*/Cache", "Library/Caches/Google/Chrome/*/Code Cache"],
             blockers: [Apps.chrome]),
    ]

    private static let mediaRoots = [".gemini/antigravity/brain", ".gemini/antigravity-ide/brain"]

    static let aiTools: [Rule] = [
        Rule(id: "claude.cache", title: "Claude Desktop: cache",
             note: "Cache Electron của app Claude.",
             category: .ai, risk: .safe,
             patterns: ["Cache", "Code Cache", "GPUCache", "DawnWebGPUCache", "GraphiteDawnCache", "Shared Dictionary"]
                .map { "Library/Application Support/Claude/\($0)" },
             blockers: [Apps.claude]),
        Rule(id: "claudecode.oldversion", title: "Claude Desktop: bản Claude Code cũ",
             note: "Bản Claude Code cũ app còn giữ. Bản mới nhất được giữ lại.",
             category: .ai, risk: .review,
             patterns: ["Library/Application Support/Claude/claude-code/*"], keepNewest: 1, blockers: [Apps.claude]),
        Rule(id: "claudecode.junk", title: "Claude Code: file tạm",
             note: "Telemetry, shell snapshot, cache và file .tmp còn sót.",
             category: .ai, risk: .safe,
             patterns: [".claude/telemetry", ".claude/cache", ".claude/shell-snapshots/*", ".claude.json.tmp.*"],
             age: .days(1)),
        Rule(id: "antigravity.junk", title: "Antigravity: log & file tạm",
             note: "Log của Gemini CLI và cache của Antigravity.",
             category: .ai, risk: .safe,
             patterns: [".gemini/antigravity/log", ".gemini/antigravity/cache", ".gemini/logs"]),
        Rule(id: "antigravity.browser", title: "Antigravity: cache trình duyệt agent",
             note: "Cache của profile trình duyệt agent. Phiên đăng nhập được giữ.",
             category: .ai, risk: .safe,
             patterns: [".gemini/antigravity-browser-profile/*/Cache", ".gemini/antigravity-browser-profile/*/Code Cache",
                        ".gemini/antigravity-browser-profile/*/GPUCache"],
             blockers: [Apps.antigravityBrowser]),
        Rule(id: "antigravity.media", title: "Antigravity: ảnh chụp tạm của agent",
             note: "Ảnh chụp màn hình và ảnh click agent tạo khi điều khiển trình duyệt. Nội dung chat được giữ nguyên.",
             category: .ai, risk: .safe,
             patterns: mediaRoots.flatMap { ["\($0)/tempmediaStorage/*", "\($0)/*/.tempmediaStorage/*",
                                             "\($0)/*/.system_generated/click_feedback/*"] },
             age: .days(7)),
        Rule(id: "antigravity.recordings", title: "Antigravity: bản quay màn hình",
             note: "Video agent quay khi kiểm thử trên trình duyệt. Bản còn nhúng trong tài liệu walkthrough được giữ lại.",
             category: .ai, risk: .safe,
             patterns: mediaRoots.flatMap { ["\($0)/*/*.webp", "\($0)/*/*.webm"] },
             age: .days(7), keepReferenced: true),
        Rule(id: "windsurf.browser", title: "Windsurf: trình duyệt tích hợp",
             note: "Chromium do Windsurf tải về để xem trước trang web, tự tải lại khi cần.",
             category: .ai, risk: .review, patterns: [".codeium/ws-browser"], blockers: [Apps.windsurf]),
        Rule(id: "codex.cache", title: "Codex: cache",
             note: "Cache tải về của Codex CLI.",
             category: .ai, risk: .safe, patterns: [".codex/cache"]),
    ]

    static let editors: [Rule] =
        ide("Antigravity IDE", folder: "Antigravity IDE", extensions: ".antigravity-ide/extensions",
            app: Apps.antigravityIDE, category: .editors)
        + ide("Antigravity", folder: "Antigravity", extensions: ".antigravity/extensions",
              app: Apps.antigravity, category: .editors)
        + ide("VS Code", folder: "Code", extensions: ".vscode/extensions", app: Apps.vscode, category: .editors)
        + ide("Cursor", folder: "Cursor", extensions: ".cursor/extensions", app: Apps.cursor, category: .editors)
        + ide("Windsurf", folder: "Windsurf", extensions: ".windsurf/extensions", app: Apps.windsurf, category: .editors)

    static let mobile: [Rule] = [
        Rule(id: "xcode.derived", title: "Xcode: DerivedData",
             note: "Kết quả build. Lần build sau sẽ lâu hơn.",
             category: .mobile, risk: .safe,
             patterns: ["Library/Developer/Xcode/DerivedData/*"], blockers: [Apps.xcode]),
        Rule(id: "xcode.ib", title: "Xcode: cache Interface Builder",
             note: "Dữ liệu render storyboard, tự tạo lại.",
             category: .mobile, risk: .safe,
             patterns: ["Library/Developer/Xcode/UserData/IB Support", "Library/Developer/Xcode/UserData/IB%20Support",
                        "Library/Caches/com.apple.dt.Xcode"],
             blockers: [Apps.xcode]),
        Rule(id: "xcode.devicesupport", title: "Xcode: Device Support",
             note: "Symbol thiết bị. Xcode tải lại khi cắm máy, mất vài phút.",
             category: .mobile, risk: .review,
             patterns: ["Library/Developer/Xcode/iOS DeviceSupport/*", "Library/Developer/Xcode/macOS DeviceSupport/*"],
             blockers: [Apps.xcode]),
        Rule(id: "gradle.daemon", title: "Gradle: daemon log",
             note: "Log của Gradle daemon các phiên bản.",
             category: .mobile, risk: .safe, patterns: [".gradle/daemon/*"], age: .days(7)),
        Rule(id: "gradle.wrapper", title: "Gradle: wrapper lâu không dùng",
             note: "Bản Gradle tải về. Dự án cần sẽ tự tải lại.",
             category: .mobile, risk: .review, patterns: [".gradle/wrapper/dists/*"], age: .days(90)),
        Rule(id: "gradle.caches", title: "Gradle: cache dependency",
             note: "Lần build Android sau phải tải lại toàn bộ dependency.",
             category: .mobile, risk: .review, patterns: [".gradle/caches"]),
        Rule(id: "android.cache", title: "Android: cache & metrics",
             note: "Cache của công cụ Android SDK.",
             category: .mobile, risk: .safe, patterns: [".android/cache", ".android/metrics"]),
        Rule(id: "android.ndk", title: "Android: NDK bản cũ",
             note: "Giữ bản NDK mới nhất.",
             category: .mobile, risk: .review, patterns: ["Library/Android/sdk/ndk/*"], keepNewest: 1),
        Rule(id: "android.snapshots", title: "Android: snapshot máy ảo",
             note: "Trạng thái lưu của máy ảo. Lần mở sau khởi động lại từ đầu. Dữ liệu trong máy ảo được giữ.",
             category: .mobile, risk: .review,
             patterns: [".android/avd/*.avd/snapshots/*"], blockers: [Apps.emulator]),
        Rule(id: "android.unusedimages", title: "Android: system image không dùng",
             note: "System image không có máy ảo nào sử dụng.",
             category: .mobile, risk: .review,
             patterns: ["Library/Android/sdk/system-images/*/*"], keepUsedSystemImages: true, blockers: [Apps.emulator]),
        Rule(id: "lldb.cache", title: "Xcode: cache LLDB",
             note: "Cache module của trình gỡ lỗi, tự tạo lại.",
             category: .mobile, risk: .safe, patterns: [".lldb/module_cache"]),
        Rule(id: "dart.server", title: "Dart Analysis Server: cache",
             note: "Index của Dart, tự tạo lại khi mở dự án.",
             category: .mobile, risk: .safe, patterns: [".dartServer"]),
        Rule(id: "pub.cache", title: "Flutter: pub cache",
             note: "Package Dart đã tải. Chạy flutter pub get để lấy lại.",
             category: .mobile, risk: .review, patterns: [".pub-cache/hosted"]),
    ]

    static let packages: [Rule] = [
        Rule(id: "npm.cache", title: "npm: cache", note: "Cache tải về của npm và npx.",
             category: .packages, risk: .safe, patterns: [".npm/_cacache", ".npm/_npx", ".npm/_logs"]),
        Rule(id: "pnpm.store", title: "pnpm: store",
             note: "node_modules hiện có vẫn chạy, nhưng lần cài sau phải tải lại.",
             category: .packages, risk: .review, patterns: ["Library/pnpm/store"]),
        Rule(id: "brew.cache", title: "Homebrew: cache", note: "Gói cài đã tải.",
             category: .packages, risk: .safe, patterns: ["Library/Caches/Homebrew"]),
        Rule(id: "misc.cache", title: "pip, Yarn, CocoaPods, Bun: cache", note: "Cache tải về.",
             category: .packages, risk: .safe,
             patterns: ["Library/Caches/pip", "Library/Caches/Yarn", "Library/Caches/CocoaPods", ".bun/install/cache"]),
        Rule(id: "maven.repo", title: "Maven: repository",
             note: "Dependency Java, tải lại khi build.",
             category: .packages, risk: .review, patterns: [".m2/repository"]),
        Rule(id: "nuget.packages", title: "NuGet: packages",
             note: "Package .NET, tải lại khi restore.",
             category: .packages, risk: .review, patterns: [".nuget/packages"]),
        Rule(id: "cargo.registry", title: "Cargo: registry cache",
             note: "Crate Rust đã tải.",
             category: .packages, risk: .review, patterns: [".cargo/registry/cache"]),
    ]

    static let temp: [Rule] = [
        Rule(id: "temp.compiler", title: "Cache trình biên dịch Clang",
             note: "Module đã biên dịch, tự tạo lại ở lần build sau.",
             category: .temp, risk: .safe, patterns: ["$TEMP/C/clang"]),
        Rule(id: "temp.shared", title: "File tạm trong /tmp",
             note: "File và profile trình duyệt tạm cũ hơn 3 ngày, không app nào đang mở.",
             category: .temp, risk: .review, patterns: ["$SHARED/*"], age: .days(3),
             exclude: ["claude-501", "cc-socks", "com.apple.launchd"]),
        Rule(id: "app.docker", title: "Bộ cài Docker còn sót",
             note: "Bản Docker tải về khi cập nhật nhưng không được dọn. Docker đang cài không ảnh hưởng.",
             category: .temp, risk: .safe,
             patterns: ["Library/Application Support/com.docker.install/in_progress"], age: .days(30)),
        Rule(id: "app.updaters", title: "Gói cập nhật ứng dụng",
             note: "Gói cài Zalo và app khác tải về để tự cập nhật.",
             category: .temp, risk: .safe,
             patterns: ["Library/Application Support/Caches/*-updater"], age: .days(7)),
        Rule(id: "app.electron", title: "Cache Canva, Zalo, pgAdmin",
             note: "Cache giao diện của các app này. Tin nhắn, thiết kế và đăng nhập được giữ.",
             category: .temp, risk: .safe,
             patterns: ["Canva", "ZaloData", "pgAdmin 4"].flatMap { app in
                 ["Cache", "Code Cache", "GPUCache"].map { "Library/Application Support/\(app)/\($0)" }
             },
             blockers: [Apps.canva, Apps.zalo]),
        Rule(id: "app.dingtalk", title: "DingTalk: log",
             note: "Log hoạt động của DingTalk. Tin nhắn không ảnh hưởng.",
             category: .temp, risk: .safe,
             patterns: ["Library/Application Support/DingTalkMac/log/*"], age: .days(7), blockers: [Apps.dingTalk]),
        Rule(id: "temp.old", title: "File tạm cũ",
             note: "File trong thư mục tạm của hệ thống, cũ hơn 3 ngày và không có app nào đang mở.",
             category: .temp, risk: .review, patterns: ["$TEMP/T/*"], age: .days(3), exclude: ["TemporaryItems"]),
    ]
}

/// Tìm các thư mục extension cũ trong tên kiểu `publisher.name-1.2.3-darwin-arm64`.
enum ExtensionVersions {
    struct Parsed {
        let key: String
        let version: [Int]
    }

    static func parse(_ name: String) -> Parsed? {
        guard let match = name.firstMatch(of: #/^(.+?)-(\d+(?:\.\d+)+)(-.*)?$/#),
              !name.hasPrefix(".") else { return nil }
        let version = match.2.split(separator: ".").compactMap { Int($0) }
        return Parsed(key: "\(match.1)\(match.3 ?? "")", version: version)
    }

    /// Trả về các tên không phải bản cao nhất của extension tương ứng.
    static func outdated(_ names: [String]) -> Set<String> {
        var groups: [String: [(name: String, version: [Int])]] = [:]
        for name in names {
            guard let parsed = parse(name) else { continue }
            groups[parsed.key, default: []].append((name, parsed.version))
        }
        var result = Set<String>()
        for entries in groups.values where entries.count > 1 {
            let highest = entries.max { $0.version.lexicographicallyPrecedes($1.version) }
            result.formUnion(entries.map(\.name).filter { $0 != highest?.name })
        }
        return result
    }
}
