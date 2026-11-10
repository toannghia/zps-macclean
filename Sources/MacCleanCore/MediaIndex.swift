import Foundation

/// Những gì đã đọc được từ một file, chỉ còn đúng khi dung lượng và ngày sửa chưa đổi.
public struct MediaFacts: Codable, Sendable {
    var size: Int64
    var modified: TimeInterval
    var width: Int?
    var height: Int?
    var fingerprint: String?
    var fullHash: String?
    var differenceHash: UInt64?
    var captureDate: TimeInterval?
}

/// Chỉ mục lưu trên máy để lần quét sau chỉ phải đọc file mới hoặc đã thay đổi.
public final class MediaIndex: @unchecked Sendable {
    public struct FolderScan: Codable, Sendable {
        public let date: Date
        public let files: Int
    }

    private struct Stored: Codable {
        var entries: [String: MediaFacts]
        var folders: [String: FolderScan]
    }

    private let lock = NSLock()
    private let location: URL?
    private var entries: [String: MediaFacts] = [:]
    private var folders: [String: FolderScan] = [:]
    private var loaded = false
    private var dirty = false

    public static let shared = MediaIndex(location: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/vn.zenpos.macclean/media-index.json"))

    /// `location` nil là chỉ mục chỉ nằm trong bộ nhớ, dùng cho test.
    public init(location: URL?) {
        self.location = location
    }

    /// Đọc từ đĩa ở lần dùng đầu tiên; gọi từ luồng nền vì file có thể vài MB.
    public func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        guard let location, let data = try? Data(contentsOf: location),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        entries = stored.entries
        folders = stored.folders
    }

    public func save() {
        lock.lock()
        guard dirty, let location else {
            lock.unlock()
            return
        }
        let stored = Stored(entries: entries, folders: folders)
        dirty = false
        lock.unlock()
        try? FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: location, options: .atomic)
        }
    }

    public func lastScan(of folder: URL) -> FolderScan? {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return folders[folder.standardizedFileURL.path]
    }

    public func recordScan(of folder: URL, files: Int) {
        lock.lock()
        folders[folder.standardizedFileURL.path] = FolderScan(date: Date(), files: files)
        dirty = true
        lock.unlock()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Lấy giá trị đã lưu nếu file chưa đổi, không thì tính rồi lưu lại.
    func value<T>(_ file: MediaFile, _ key: WritableKeyPath<MediaFacts, T?>, compute: () -> T?) -> T? {
        let modified = file.modified.timeIntervalSinceReferenceDate
        lock.lock()
        if let facts = entries[file.id], facts.size == file.size, facts.modified == modified,
           let cached = facts[keyPath: key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let fresh = compute()
        guard let fresh else { return nil }
        lock.lock()
        var facts = entries[file.id] ?? MediaFacts(size: file.size, modified: modified)
        if facts.size != file.size || facts.modified != modified {
            facts = MediaFacts(size: file.size, modified: modified)
        }
        facts[keyPath: key] = fresh
        entries[file.id] = facts
        dirty = true
        lock.unlock()
        return fresh
    }
}

extension MediaFacts {
    init(size: Int64, modified: TimeInterval) {
        self.size = size
        self.modified = modified
    }
}

extension MediaIndex {
    public func dimensions(_ file: MediaFile) -> (width: Int, height: Int)? {
        Optional(self).dimensions(file)
    }
}

/// Các phép đọc file có thể lấy lại từ chỉ mục.
extension MediaIndex? {
    func dimensions(_ file: MediaFile) -> (width: Int, height: Int)? {
        guard let index = self else { return MediaScanner.dimensions(file.url) }
        let width = index.value(file, \.width) { MediaScanner.dimensions(file.url)?.width }
        let height = index.value(file, \.height) { MediaScanner.dimensions(file.url)?.height }
        guard let width, let height else { return nil }
        return (width, height)
    }

    func fingerprint(_ file: MediaFile) -> String? {
        guard let index = self else { return DuplicateFinder.quickFingerprint(file) }
        return index.value(file, \.fingerprint) { DuplicateFinder.quickFingerprint(file) }
    }

    func fullHash(_ file: MediaFile) -> String? {
        guard let index = self else { return DuplicateFinder.sha256(file.url) }
        return index.value(file, \.fullHash) { DuplicateFinder.sha256(file.url) }
    }

    func differenceHash(_ file: MediaFile) -> UInt64? {
        guard let index = self else { return DuplicateFinder.differenceHash(file.url) }
        return index.value(file, \.differenceHash) { DuplicateFinder.differenceHash(file.url) }
    }

    func captureDate(_ file: MediaFile) -> Date {
        guard let index = self else { return MediaScanner.captureDate(of: file) }
        let seconds = index.value(file, \.captureDate) { MediaScanner.captureDate(of: file).timeIntervalSinceReferenceDate }
        return seconds.map(Date.init(timeIntervalSinceReferenceDate:)) ?? file.modified
    }
}
