import Foundation

/// Mức rủi ro quyết định mục có được tick sẵn và được xoá theo cách nào.
public enum Risk: Int, Comparable, CaseIterable, Sendable {
    /// Cache thuần, tự sinh lại. Tick sẵn.
    case safe
    /// Tự lấy lại được nhưng tốn thời gian tải/build. Người dùng tự tick.
    case review

    public static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .safe: return "An toàn"
        case .review: return "Cân nhắc"
        }
    }
}

public enum CleanCategory: String, CaseIterable, Identifiable, Sendable {
    case browsers, ai, editors, docker, mobile, packages, projects, temp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .browsers: return "Trình duyệt"
        case .ai: return "Công cụ AI"
        case .editors: return "IDE & Editor"
        case .docker: return "Docker"
        case .mobile: return "Xcode & Android"
        case .packages: return "Package manager"
        case .projects: return "Rác trong dự án"
        case .temp: return "File tạm"
        }
    }

    public var symbol: String {
        switch self {
        case .browsers: return "globe"
        case .ai: return "sparkles"
        case .editors: return "chevron.left.forwardslash.chevron.right"
        case .docker: return "shippingbox"
        case .mobile: return "iphone"
        case .packages: return "archivebox"
        case .projects: return "folder"
        case .temp: return "trash"
        }
    }
}

public enum CleanAction: Equatable, Sendable {
    case delete([URL])
    case command(executable: String, arguments: [String])

    public var urls: [URL] {
        switch self {
        case .delete(let urls): return urls
        case .command: return []
        }
    }
}

public struct CleanItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let note: String
    public let category: CleanCategory
    public let risk: Risk
    public let action: CleanAction
    public let size: Int64
    /// Tên app đang chạy khiến mục này chưa dọn được.
    public var blockedBy: [String]
    /// Chỉ báo cần quét lại quy tắc nào; dùng để kiểm tra ngay trước khi xoá.
    public let blockHints: [AppHint]
    /// Số đường dẫn được giữ lại vì đang mở hoặc vừa dùng.
    public var skippedInUse: Int

    public init(id: String, title: String, note: String, category: CleanCategory, risk: Risk,
                action: CleanAction, size: Int64, blockedBy: [String] = [],
                blockHints: [AppHint] = [], skippedInUse: Int = 0) {
        self.id = id
        self.title = title
        self.note = note
        self.category = category
        self.risk = risk
        self.action = action
        self.size = size
        self.blockedBy = blockedBy
        self.blockHints = blockHints
        self.skippedInUse = skippedInUse
    }

    public var isBlocked: Bool { !blockedBy.isEmpty }
}

/// Tên hiển thị của một app và chuỗi để nhận ra nó trong danh sách tiến trình.
public struct AppHint: Hashable, Sendable {
    public let name: String
    public let match: String

    public init(_ name: String, match: String) {
        self.name = name
        self.match = match
    }
}

public struct ScanOptions: Sendable {
    /// Dự án có thay đổi trong số ngày này được xem là đang làm và bỏ qua.
    public var retentionDays: Int
    public var projectRoots: [URL]

    public init(retentionDays: Int = 30, projectRoots: [URL] = []) {
        self.retentionDays = retentionDays
        self.projectRoots = projectRoots
    }
}

/// Tiến độ hiển thị cho người dùng khi quét hoặc dọn.
public struct WorkProgress: Sendable {
    public var fraction: Double
    public var phase: String
    public var detail: String
    public var foundBytes: Int64

    public init(fraction: Double = 0, phase: String = "", detail: String = "", foundBytes: Int64 = 0) {
        self.fraction = fraction
        self.phase = phase
        self.detail = detail
        self.foundBytes = foundBytes
    }
}

public struct DiskInfo: Identifiable, Sendable {
    public let name: String
    public let free: Int64
    public let total: Int64
    public var id: String { name }

    public init(name: String, free: Int64, total: Int64) {
        self.name = name
        self.free = free
        self.total = total
    }
}

public struct CleanReport: Sendable {
    public var estimatedBytes: Int64 = 0
    /// Dung lượng trống thực tăng thêm, đo từ ổ đĩa trước và sau khi dọn.
    public var actualFreedBytes: Int64 = 0
    /// Phần dung lượng trống tăng thêm trên từng ổ.
    public var freedByDisk: [DiskInfo] = []
    public var cleanedCount = 0
    public var failures: [String] = []

    public init() {}
}
