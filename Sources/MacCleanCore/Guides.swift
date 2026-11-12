import Foundation

/// Giải thích một mục để người dùng tự quyết định có xoá hay không.
public struct ItemGuide: Sendable {
    public let name: String
    public let what: String
    public let ifDeleted: String
    public let restore: String
    public let advice: String

    public init(name: String, what: String, ifDeleted: String, restore: String, advice: String) {
        self.name = name
        self.what = what
        self.ifDeleted = ifDeleted
        self.restore = restore
        self.advice = advice
    }
}

public struct GuideSection: Identifiable, Sendable {
    public let title: String
    public let guides: [ItemGuide]
    public var id: String { title }

    public init(title: String, guides: [ItemGuide]) {
        self.title = title
        self.guides = guides
    }
}

public enum Guides {
    /// Mục không bao giờ xuất hiện trong app, dù cũ tới đâu.
    public static let neverTouched = [
        "Lịch sử chat và phiên làm việc của Claude Code, Antigravity, Gemini CLI, Codex (riêng ảnh tạm và bản quay của Antigravity thì dọn được)",
        "Thư mục memory, bản lưu file, kế hoạch và todo của công cụ AI",
        "Token và thông tin đăng nhập (.ssh, oauth, Keychain)",
        "Máy ảo Claude, trạng thái workspace của IDE",
        "Xcode Archives, nhật ký thiết bị, máy ảo Android",
        "Image, container và volume của Docker",
        "Mã nguồn, thư mục .git, file .env trong dự án",
        "Nội dung Thùng rác",
    ]

    public static let protections = [
        "App khoá mục có app liên quan đang chạy và kiểm tra lại ngay trước khi xoá.",
        "File hoặc thư mục đang được mở thì giữ lại, kể cả bản Chrome đang chạy.",
        "Dữ liệu vừa ghi trong 2 giờ gần nhất được coi là đang dùng.",
        "Dự án có tiến trình đang chạy bên trong hoặc mới sửa gần đây được bỏ qua.",
        "Không kiểm tra được file đang mở thì app dừng, không xoá gì.",
        "Mọi lần xoá được ghi vào nhật ký tại ~/Library/Logs/ZPS-MacClean/clean.log.",
    ]

    public static func guide(forItem id: String) -> ItemGuide? {
        if let exact = byRule[id] { return exact }
        guard let suffix = id.split(separator: ".").last else { return nil }
        return ideGuides[String(suffix)]
    }

    public static func artifactGuide(named name: String) -> ItemGuide? {
        projectArtifacts.first { $0.name == name }
    }

    public static var sections: [GuideSection] {
        [
            GuideSection(title: "Rác trong dự án", guides: projectArtifacts),
            GuideSection(title: "Trình duyệt", guides: ["browser.clones", "browser.crx", "browser.chromecache"].compactMap { byRule[$0] }),
            GuideSection(title: "Công cụ AI", guides: ["claude.cache", "claudecode.oldversion", "claudecode.junk", "windsurf.browser", "antigravity.junk",
                                                       "antigravity.browser", "antigravity.media", "antigravity.recordings",
                                                       "codex.cache"].compactMap { byRule[$0] }),
            GuideSection(title: "IDE & Editor", guides: ["cache", "vsix", "oldext"].compactMap { ideGuides[$0] }),
            GuideSection(title: "Docker", guides: ["docker.builder"].compactMap { byRule[$0] }),
            GuideSection(title: "Xcode & Android", guides: [
                "xcode.derived", "xcode.ib", "xcode.devicesupport", "gradle.daemon", "gradle.wrapper",
                "gradle.caches", "android.cache", "android.ndk", "android.snapshots", "android.unusedimages",
                "lldb.cache", "dart.server", "pub.cache",
            ].compactMap { byRule[$0] }),
            GuideSection(title: "Package manager", guides: ["npm.cache", "pnpm.store", "brew.cache", "misc.cache",
                                                            "maven.repo", "nuget.packages", "cargo.registry"].compactMap { byRule[$0] }),
            GuideSection(title: "Ảnh & Video", guides: [
                ItemGuide(name: "Ảnh trùng",
                          what: "Tìm file giống hệt nhau, và tuỳ chọn tìm ảnh nhìn giống nhau như bản đã nén lại hoặc đổi kích thước. File dưới 256 MB được so từng byte; file lớn hơn như video dài được so dung lượng cùng 32 đoạn rải đều khắp file, để không phải đọc hết hàng chục GB.",
                          ifDeleted: "App không chọn sẵn file nào; chỉ file bạn bấm chọn mới được chuyển vào Thùng rác, và chưa mất cho tới khi đổ Thùng rác. Mỗi nhóm luôn giữ ít nhất một bản.",
                          restore: "Mở Thùng rác, chọn file rồi bấm Đưa trở lại.",
                          advice: "App tự dừng quét nếu dùng quá nhiều bộ nhớ, kết quả đến lúc đó vẫn được giữ. Nhóm Giống hệt nhau xoá an toàn. Nhóm Nhìn giống nhau nên xem kỹ, vì ảnh chụp liên tiếp cũng có thể bị xếp chung."),
                ItemGuide(name: "Nén ảnh",
                          what: "Lưu lại ảnh JPEG, HEIC ở chất lượng thấp hơn, tuỳ chọn thu nhỏ và đổi sang HEIC. Giữ thông tin EXIF như ngày chụp, vị trí. Không động tới RAW và GIF.",
                          ifDeleted: "Mặc định bản gốc giữ nguyên, bản nén nằm trong thư mục \"ZPS Đã nén\". Khi chọn ghi đè, bản gốc vào Thùng rác.",
                          restore: "Bản nén đã mất chi tiết, không phục hồi được. Lấy lại bản gốc trong Thùng rác.",
                          advice: "Chất lượng 75-85% thường khó thấy khác biệt. Thử trên vài ảnh trước khi chọn ghi đè."),
                ItemGuide(name: "Sắp xếp ảnh",
                          what: "Xếp ảnh và video vào thư mục theo ngày chụp, ví dụ 2026/2026-11, ngay trong thư mục đã chọn. Không bao giờ ghi đè file trùng tên.",
                          ifDeleted: "Không xoá gì. Chế độ Chuyển đổi chỗ file; chế độ Chép giữ nguyên bản gốc.",
                          restore: "Bấm Hoàn tác ngay sau khi xếp. Danh sách đã chuyển cũng được lưu trong ~/Library/Logs/ZPS-MacClean.",
                          advice: "Bấm Xem trước để kiểm tra. Không chọn thư mục mà phần mềm khác đang quản lý theo đường dẫn cố định."),
                ItemGuide(name: "Nén video",
                          what: "Nén lại video với bitrate như các nền tảng video, bằng bộ mã hoá phần cứng của Mac, ra file MP4. Dung lượng giảm vì bitrate thấp hơn, không phải vì đổi đuôi: video iPhone 4K thường 50–100 Mbps, bản 1080p cân bằng chỉ khoảng 4–6 Mbps. Giữ ngày quay, vị trí, chiều quay và màu HDR.",
                          ifDeleted: "Mặc định bản gốc giữ nguyên. Khi chọn ghi đè, bản gốc vào Thùng rác nếu bản nén nhỏ hơn.",
                          restore: "Lấy lại bản gốc trong Thùng rác.",
                          advice: "Cân bằng 1080p hợp cho hầu hết video điện thoại: một video 4K 1,8 GB còn khoảng 126 MB mà xem bình thường khó thấy khác. Nhỏ gọn 720p nhẹ hơn nữa nhưng mềm hình hơn. Chọn Tương thích H.264 nếu cần mở trên máy cũ hoặc Windows. Video đã ở bitrate thấp sẽ được giữ nguyên."),
            ]),
            GuideSection(title: "Tiến trình", guides: [
                ItemGuide(name: "Tắt và Buộc tắt",
                          what: "Màn hình Tiến trình gộp tiến trình theo ứng dụng và cập nhật mỗi 3 giây. RAM đo theo cách của Activity Monitor; CPU có thể vượt 100% vì tính trên từng lõi.",
                          ifDeleted: "Tắt yêu cầu app thoát và cho nó cơ hội hỏi lưu file. Buộc tắt dừng ngay, dữ liệu chưa lưu sẽ mất.",
                          restore: "Mở lại app. Phần chưa lưu khi Buộc tắt không lấy lại được.",
                          advice: "Luôn dùng Tắt trước, chỉ Buộc tắt khi app treo. Tiến trình hệ thống được ẩn sẵn; bật ô Hiện tiến trình hệ thống để xem, chúng có biểu tượng khoá và không tắt được."),
            ]),
            GuideSection(title: "File tạm", guides: ["temp.compiler", "temp.old", "temp.shared", "app.docker", "app.updaters",
                                                     "app.electron", "app.dingtalk"].compactMap { byRule[$0] }),
        ]
    }

    /// "Rác trong dự án" là thư mục sinh ra khi cài đặt hoặc build, không phải mã nguồn.
    public static let projectArtifacts = [
        ItemGuide(name: "node_modules",
                  what: "Thư viện JavaScript tải về theo package.json. Thường là thư mục nặng nhất của dự án web.",
                  ifDeleted: "Dự án không chạy được cho tới khi cài lại. Mã nguồn không ảnh hưởng.",
                  restore: "Chạy npm install, pnpm install hoặc yarn trong thư mục dự án. Cần mạng.",
                  advice: "Nên xoá với dự án đã bàn giao hoặc tạm dừng. Dự án cũ có thể cài lại ra phiên bản khác nếu thiếu file lock."),
        ItemGuide(name: ".next",
                  what: "Kết quả build và cache của Next.js.",
                  ifDeleted: "Lần chạy hoặc build sau lâu hơn một chút.",
                  restore: "Tự tạo lại khi chạy npm run dev hoặc npm run build.",
                  advice: "Xoá thoải mái. Nếu dùng bản build này để deploy trực tiếp thì build lại trước."),
        ItemGuide(name: ".nuxt",
                  what: "Kết quả build và file sinh tự động của Nuxt.",
                  ifDeleted: "Lần chạy sau lâu hơn một chút.",
                  restore: "Tự tạo lại khi chạy dev hoặc build.",
                  advice: "Xoá thoải mái."),
        ItemGuide(name: ".svelte-kit",
                  what: "File sinh tự động của SvelteKit.",
                  ifDeleted: "Lần chạy sau lâu hơn một chút.",
                  restore: "Tự tạo lại khi chạy dev hoặc build.",
                  advice: "Xoá thoải mái."),
        ItemGuide(name: ".turbo",
                  what: "Cache build của Turborepo.",
                  ifDeleted: "Lần build sau chạy đầy đủ thay vì dùng kết quả cũ.",
                  restore: "Tự tạo lại khi build.",
                  advice: "Xoá thoải mái."),
        ItemGuide(name: ".angular",
                  what: "Cache build của Angular CLI.",
                  ifDeleted: "Lần build sau chậm hơn.",
                  restore: "Tự tạo lại khi build.",
                  advice: "Xoá thoải mái."),
        ItemGuide(name: ".dart_tool",
                  what: "Cấu hình package và cache của Dart/Flutter trong dự án.",
                  ifDeleted: "Cần chạy lại pub get trước khi build.",
                  restore: "Chạy flutter pub get. flutter run cũng tự làm việc này.",
                  advice: "Nên xoá với dự án Flutter đã tạm dừng."),
        ItemGuide(name: "build",
                  what: "Kết quả build của Flutter: file trung gian, APK, app. Chỉ nhận thư mục này khi dự án có pubspec.yaml.",
                  ifDeleted: "Mất các bản APK/IPA đã build nằm trong thư mục này. Lần build sau chạy lại từ đầu.",
                  restore: "Chạy flutter build.",
                  advice: "Nếu còn cần file APK/IPA đã build, hãy chép ra chỗ khác trước khi xoá."),
        ItemGuide(name: "Pods",
                  what: "Thư viện iOS do CocoaPods tải về theo Podfile.",
                  ifDeleted: "Dự án iOS không build được cho tới khi cài lại.",
                  restore: "Chạy pod install trong thư mục ios. Cần mạng.",
                  advice: "Nên xoá với dự án đã tạm dừng. Giữ lại nếu Podfile.lock đã mất."),
        ItemGuide(name: "target",
                  what: "Kết quả build của Rust (Cargo.toml) hoặc Java (pom.xml).",
                  ifDeleted: "Mất file jar hoặc binary đã build trong thư mục này. Lần build sau chạy lại từ đầu.",
                  restore: "Chạy cargo build hoặc mvn package.",
                  advice: "Nếu còn cần file jar đã build, hãy chép ra chỗ khác trước khi xoá."),
        ItemGuide(name: ".gradle",
                  what: "Cache build của Gradle riêng cho dự án.",
                  ifDeleted: "Lần build sau chậm hơn.",
                  restore: "Tự tạo lại khi build.",
                  advice: "Xoá thoải mái."),
        ItemGuide(name: ".venv",
                  what: "Môi trường ảo Python chứa thư viện đã cài của dự án.",
                  ifDeleted: "Dự án Python không chạy được cho tới khi tạo lại môi trường.",
                  restore: "Tạo lại venv rồi cài theo requirements.txt hoặc pyproject.toml.",
                  advice: "Giữ lại nếu thư viện từng được cài tay mà chưa ghi vào file requirements."),
    ]

    private static let ideGuides: [String: ItemGuide] = [
        "cache": ItemGuide(name: "Cache & log của IDE",
                           what: "Cache giao diện, code đã biên dịch của Electron, log và báo cáo crash.",
                           ifDeleted: "Lần mở sau chậm hơn vài giây. Code, cài đặt, extension và lịch sử chat không ảnh hưởng.",
                           restore: "IDE tự tạo lại khi mở.",
                           advice: "Nên xoá. Cần đóng IDE trước, app sẽ khoá mục này khi IDE đang chạy."),
        "vsix": ItemGuide(name: "Gói extension đã tải",
                          what: "File cài .vsix IDE giữ lại sau khi đã cài extension xong.",
                          ifDeleted: "Extension đã cài vẫn chạy bình thường.",
                          restore: "IDE tự tải lại khi cần cài hoặc cập nhật.",
                          advice: "Nên xoá."),
        "oldext": ItemGuide(name: "Extension bản cũ",
                            what: "Các phiên bản cũ của extension còn sót lại sau khi cập nhật. Bản mới nhất luôn được giữ.",
                            ifDeleted: "Không quay lại bản cũ ngay được. Extension đang dùng không ảnh hưởng.",
                            restore: "Cài lại bản cũ từ Marketplace nếu cần.",
                            advice: "Nên xoá, trừ khi bạn cố tình ghim một phiên bản cũ của extension."),
    ]

    private static let byRule: [String: ItemGuide] = [
        "browser.crx": ItemGuide(
            name: "Gói cập nhật trình duyệt",
            what: "Gói cài extension và thành phần Chrome, Cốc Cốc giữ lại sau khi cập nhật.",
            ifDeleted: "Extension đã cài vẫn chạy bình thường.",
            restore: "Trình duyệt tự tải lại khi cần.",
            advice: "Nên xoá. Cần đóng trình duyệt trước."),
        "claudecode.oldversion": ItemGuide(
            name: "Bản Claude Code cũ",
            what: "Bản Claude Code cũ Claude Desktop còn giữ sau khi cập nhật.",
            ifDeleted: "Không quay lại bản cũ ngay được. Phiên và lịch sử không ảnh hưởng.",
            restore: "Claude Desktop tự tải khi cần.",
            advice: "Nên xoá khi đã thoát Claude Desktop."),
        "windsurf.browser": ItemGuide(
            name: "Trình duyệt tích hợp Windsurf",
            what: "Chromium Windsurf tải về để xem trước trang web.",
            ifDeleted: "Lần dùng sau phải tải lại.",
            restore: "Windsurf tự tải lại. Cần mạng.",
            advice: "Xoá nếu không dùng Windsurf thường xuyên."),
        "android.snapshots": ItemGuide(
            name: "Snapshot máy ảo Android",
            what: "Trạng thái đóng băng để máy ảo mở nhanh.",
            ifDeleted: "Lần mở sau khởi động từ đầu, mất vài phút. App và dữ liệu trong máy ảo vẫn còn.",
            restore: "Emulator tạo snapshot mới khi tắt.",
            advice: "Nên xoá."),
        "android.unusedimages": ItemGuide(
            name: "System image không dùng",
            what: "Hệ điều hành Android đã tải nhưng không có máy ảo nào trỏ tới.",
            ifDeleted: "Tạo máy ảo mới bằng image đó phải tải lại.",
            restore: "Tải lại trong SDK Manager. Cần mạng.",
            advice: "Nên xoá."),
        "lldb.cache": ItemGuide(
            name: "Cache LLDB",
            what: "Cache module của trình gỡ lỗi LLDB.",
            ifDeleted: "Lần debug sau khởi động chậm hơn.",
            restore: "Tự tạo lại.",
            advice: "Nên xoá."),
        "temp.compiler": ItemGuide(
            name: "Cache Clang",
            what: "Module đã biên dịch của Clang.",
            ifDeleted: "Lần build sau chậm hơn một chút.",
            restore: "Tự tạo lại.",
            advice: "Nên xoá."),
        "temp.shared": ItemGuide(
            name: "File tạm trong /tmp",
            what: "File và profile trình duyệt tạm cũ hơn 3 ngày, ví dụ thư mục do công cụ kiểm thử tạo ra.",
            ifDeleted: "macOS vốn có thể tự xoá khu vực này. File xuất tạm chưa lưu nơi khác sẽ mất.",
            restore: "Không khôi phục được.",
            advice: "Bấm mũi tên xem danh sách. Có file còn cần thì chép ra trước."),
        "app.docker": ItemGuide(
            name: "Bộ cài Docker còn sót",
            what: "Bản Docker.app tải về lúc cập nhật nhưng không được dọn. Chỉ tính khi đã nằm hơn 30 ngày.",
            ifDeleted: "Docker đang cài trong Applications không ảnh hưởng.",
            restore: "Docker tự tải khi cập nhật.",
            advice: "Nên xoá."),
        "app.updaters": ItemGuide(
            name: "Gói cập nhật ứng dụng",
            what: "Gói cài Zalo và app khác tải về để tự cập nhật.",
            ifDeleted: "App đã cài không ảnh hưởng.",
            restore: "App tự tải lại khi có bản mới.",
            advice: "Nên xoá."),
        "app.electron": ItemGuide(
            name: "Cache Canva, Zalo, pgAdmin",
            what: "Cache giao diện, không phải dữ liệu chính của app.",
            ifDeleted: "Lần mở sau chậm hơn một chút. Tin nhắn, thiết kế và đăng nhập không ảnh hưởng.",
            restore: "App tự tạo lại.",
            advice: "Nên xoá. Cần đóng app trước."),
        "app.dingtalk": ItemGuide(
            name: "Log DingTalk",
            what: "Log hoạt động của DingTalk.",
            ifDeleted: "Mất log cũ, chỉ cần khi báo lỗi. Tin nhắn không ảnh hưởng.",
            restore: "Log mới tự ghi.",
            advice: "Nên xoá."),
        "browser.clones": ItemGuide(
            name: "Bản sao code-sign của trình duyệt",
            what: "Mỗi lần chạy, Chrome và Brave tạo một bản sao toàn bộ app trong thư mục tạm của hệ thống để kiểm tra chữ ký. Bản cũ không được dọn nên chất đống.",
            ifDeleted: "Không mất gì: mật khẩu, tab, lịch sử, bookmark nằm ở nơi khác. Bản đang chạy được giữ nguyên.",
            restore: "Trình duyệt tự tạo bản mới khi khởi động.",
            advice: "Nên xoá. Các bản sao dùng chung dữ liệu trên APFS nên app chỉ tính dung lượng một bản. Trình duyệt không tự dọn nên chúng sẽ quay lại theo thời gian."),
        "browser.chromecache": ItemGuide(
            name: "Cache Google Chrome",
            what: "Ảnh và file trang web Chrome lưu lại để mở nhanh hơn.",
            ifDeleted: "Trang web tải lại lần đầu chậm hơn. Không đăng xuất, không mất lịch sử.",
            restore: "Tự tạo lại khi duyệt web.",
            advice: "Chỉ xoá khi cần thêm dung lượng."),
        "claude.cache": ItemGuide(
            name: "Cache Claude Desktop",
            what: "Cache giao diện Electron của app Claude.",
            ifDeleted: "Lần mở sau chậm hơn một chút. Hội thoại không ảnh hưởng.",
            restore: "App tự tạo lại.",
            advice: "Nên xoá. Cần thoát hẳn Claude Desktop trước."),
        "claudecode.junk": ItemGuide(
            name: "File tạm Claude Code",
            what: "Telemetry chờ gửi, cache, shell snapshot và file .tmp còn sót lại.",
            ifDeleted: "Không ảnh hưởng tới phiên, memory hay lịch sử.",
            restore: "Tự tạo lại khi dùng.",
            advice: "Nên xoá."),
        "antigravity.junk": ItemGuide(
            name: "Log Antigravity & Gemini CLI",
            what: "Log hoạt động và cache tạm.",
            ifDeleted: "Mất log cũ, chỉ cần khi điều tra lỗi. Hội thoại không ảnh hưởng.",
            restore: "Log mới tự ghi khi dùng.",
            advice: "Nên xoá, trừ khi đang gửi log cho bộ phận hỗ trợ."),
        "antigravity.browser": ItemGuide(
            name: "Cache trình duyệt agent",
            what: "Cache của trình duyệt mà agent Antigravity điều khiển.",
            ifDeleted: "Phiên đăng nhập trong profile được giữ. Trang web tải lại chậm hơn lần đầu.",
            restore: "Tự tạo lại.",
            advice: "Nên xoá."),
        "antigravity.media": ItemGuide(
            name: "Ảnh chụp tạm của agent",
            what: "Ảnh agent chụp màn hình để quan sát trình duyệt và ảnh đánh dấu vị trí click. Chỉ gồm ảnh cũ hơn 7 ngày.",
            ifDeleted: "Một số ảnh trong hội thoại cũ có thể không hiện nữa. Nội dung chat, kế hoạch và tài liệu không ảnh hưởng.",
            restore: "Không lấy lại được ảnh cũ. Agent tạo ảnh mới khi làm việc.",
            advice: "Nên xoá."),
        "antigravity.recordings": ItemGuide(
            name: "Bản quay màn hình Antigravity",
            what: "Video .webp, .webm agent quay lại khi tự kiểm thử trên trình duyệt. Chỉ gồm bản cũ hơn 7 ngày.",
            ifDeleted: "Không xem lại được video đó trong hội thoại cũ. Bản nào còn nhúng trong walkthrough hoặc tài liệu của phiên được giữ lại.",
            restore: "Không lấy lại được.",
            advice: "Nên xoá, trừ khi cần giữ video làm bằng chứng kiểm thử. Khi đó hãy chép ra chỗ khác trước."),
        "codex.cache": ItemGuide(
            name: "Cache Codex",
            what: "File tải về tạm của Codex CLI.",
            ifDeleted: "Phiên và lịch sử không ảnh hưởng.",
            restore: "Tự tải lại khi cần.",
            advice: "Nên xoá."),
        "docker.builder": ItemGuide(
            name: "Docker build cache",
            what: "Các lớp trung gian Docker giữ lại để build image nhanh hơn. Chỉ gồm cache không có build nào đang dùng.",
            ifDeleted: "Lần docker build tiếp theo chạy lại từ đầu và tải lại base layer. Image, container và volume không bị đụng tới.",
            restore: "Tự tạo lại khi build.",
            advice: "Xoá nếu không build thường xuyên. Dung lượng trả về macOS dần dần, không ngay lập tức."),
        "xcode.derived": ItemGuide(
            name: "DerivedData",
            what: "Kết quả build và index của Xcode.",
            ifDeleted: "Lần build sau chạy lại từ đầu. Mã nguồn không ảnh hưởng.",
            restore: "Xcode tự tạo lại.",
            advice: "Nên xoá. Cần đóng Xcode trước."),
        "xcode.ib": ItemGuide(
            name: "Cache Interface Builder",
            what: "Dữ liệu Xcode dùng để hiển thị storyboard và xib.",
            ifDeleted: "Lần mở storyboard sau chậm hơn.",
            restore: "Xcode tự tạo lại.",
            advice: "Nên xoá."),
        "xcode.devicesupport": ItemGuide(
            name: "Device Support",
            what: "Symbol của từng phiên bản iOS/macOS lấy từ thiết bị đã cắm vào máy.",
            ifDeleted: "Lần cắm thiết bị sau Xcode phải chuẩn bị lại vài phút.",
            restore: "Xcode tự lấy lại khi cắm thiết bị.",
            advice: "Xoá nếu không còn test trên các phiên bản iOS cũ."),
        "gradle.daemon": ItemGuide(
            name: "Log Gradle daemon",
            what: "Log của Gradle daemon các phiên bản.",
            ifDeleted: "Mất log cũ.",
            restore: "Log mới tự ghi.",
            advice: "Nên xoá."),
        "gradle.wrapper": ItemGuide(
            name: "Gradle wrapper",
            what: "Các bản Gradle tải về theo từng dự án. Chỉ gồm bản 90 ngày không đụng tới.",
            ifDeleted: "Dự án cần bản đó sẽ phải tải lại ở lần build sau.",
            restore: "Gradle tự tải lại. Cần mạng.",
            advice: "Nên xoá nếu máy không làm dự án Android cũ."),
        "gradle.caches": ItemGuide(
            name: "Cache dependency Gradle",
            what: "Thư viện Java/Android đã tải.",
            ifDeleted: "Lần build Android sau tải lại toàn bộ, có thể mất nhiều phút.",
            restore: "Tự tải lại khi build. Cần mạng.",
            advice: "Chỉ xoá khi thật sự cần dung lượng."),
        "android.cache": ItemGuide(
            name: "Cache Android",
            what: "Cache và số liệu của công cụ Android SDK.",
            ifDeleted: "Không ảnh hưởng tới máy ảo hay dự án.",
            restore: "Tự tạo lại.",
            advice: "Nên xoá."),
        "android.ndk": ItemGuide(
            name: "NDK bản cũ",
            what: "Bộ công cụ C/C++ cho Android. Bản mới nhất được giữ.",
            ifDeleted: "Dự án ghim đúng bản NDK cũ sẽ báo thiếu khi build.",
            restore: "Cài lại qua SDK Manager của Android Studio.",
            advice: "Kiểm tra ndkVersion trong dự án trước khi xoá."),
        "dart.server": ItemGuide(
            name: "Cache Dart Analysis Server",
            what: "Index Dart dùng cho gợi ý code.",
            ifDeleted: "Lần mở dự án Flutter sau phải phân tích lại.",
            restore: "Tự tạo lại.",
            advice: "Nên xoá."),
        "pub.cache": ItemGuide(
            name: "Pub cache",
            what: "Package Dart/Flutter dùng chung cho mọi dự án.",
            ifDeleted: "Mọi dự án Flutter cần chạy lại pub get trước khi build.",
            restore: "Chạy flutter pub get. Cần mạng.",
            advice: "Chỉ xoá khi không làm Flutter trong thời gian tới."),
        "npm.cache": ItemGuide(
            name: "Cache npm",
            what: "Gói npm đã tải và các lệnh npx chạy tạm.",
            ifDeleted: "node_modules hiện có vẫn chạy. Lần cài sau tải lại.",
            restore: "Tự tải lại. Cần mạng.",
            advice: "Nên xoá."),
        "pnpm.store": ItemGuide(
            name: "pnpm store",
            what: "Kho package dùng chung của pnpm.",
            ifDeleted: "Dự án đã cài vẫn chạy. Lần cài sau tải lại.",
            restore: "Tự tải lại. Cần mạng.",
            advice: "Chỉ xoá khi cần thêm dung lượng."),
        "brew.cache": ItemGuide(
            name: "Cache Homebrew",
            what: "File cài của các gói đã tải.",
            ifDeleted: "Phần mềm đã cài không ảnh hưởng.",
            restore: "Homebrew tải lại khi cần.",
            advice: "Nên xoá."),
        "misc.cache": ItemGuide(
            name: "Cache pip, Yarn, CocoaPods, Bun",
            what: "File tải về của các công cụ quản lý gói.",
            ifDeleted: "Dự án đã cài không ảnh hưởng.",
            restore: "Tự tải lại khi cần.",
            advice: "Nên xoá."),
        "maven.repo": ItemGuide(
            name: "Maven repository",
            what: "Thư viện Java đã tải.",
            ifDeleted: "Lần build Java sau tải lại toàn bộ. Thư viện nội bộ cài bằng mvn install sẽ mất.",
            restore: "Tự tải lại khi build. Thư viện nội bộ phải cài lại.",
            advice: "Giữ lại nếu có thư viện nội bộ không có trên repository."),
        "nuget.packages": ItemGuide(
            name: "NuGet packages",
            what: "Thư viện .NET đã tải.",
            ifDeleted: "Lần build .NET sau phải restore lại.",
            restore: "Chạy dotnet restore. Cần mạng.",
            advice: "Chỉ xoá khi không làm .NET thường xuyên."),
        "cargo.registry": ItemGuide(
            name: "Cargo registry",
            what: "Crate Rust đã tải.",
            ifDeleted: "Lần build Rust sau tải lại.",
            restore: "Tự tải lại. Cần mạng.",
            advice: "Chỉ xoá khi cần thêm dung lượng."),
        "temp.old": ItemGuide(
            name: "File tạm cũ",
            what: "File các app để lại trong thư mục tạm của macOS, cũ hơn 3 ngày và không có app nào đang mở.",
            ifDeleted: "Thông thường không ảnh hưởng. Một số file xuất tạm chưa lưu ở nơi khác sẽ mất.",
            restore: "Không khôi phục được, app sẽ tự tạo file mới khi cần.",
            advice: "Bấm mũi tên ở mục này để xem danh sách. Nếu có kết quả xuất tạm còn cần, hãy lưu ra trước."),
    ]
}
