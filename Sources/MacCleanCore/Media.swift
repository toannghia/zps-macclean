import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Cờ dừng dùng chung giữa giao diện và các luồng đang quét.
public final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    public init() {}

    public var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        stopped = false
        lock.unlock()
    }
}

/// Chạy một việc trên mọi lõi CPU, giữ đúng thứ tự kết quả; mục chưa làm khi bị dừng là nil.
public enum Parallel {
    /// Số việc đọc đĩa chạy cùng lúc. Nhiều hơn không nhanh hơn mà chỉ tốn bộ nhớ, nhất là với ổ gắn ngoài.
    public static let diskWidth = 4

    /// `width` giới hạn số luồng chạy cùng lúc; mặc định dùng hết số lõi.
    public static func map<T, R>(_ items: [T], stop: StopFlag? = nil, width: Int? = nil,
                                 progress: ((Double) -> Void)? = nil, _ transform: (T) -> R?) -> [R?] {
        guard !items.isEmpty else { return [] }
        var results = [R?](repeating: nil, count: items.count)
        let lanes = max(1, min(width ?? ProcessInfo.processInfo.activeProcessorCount, items.count))
        let lock = NSLock()
        var next = 0
        var finished = 0
        let step = max(1, items.count / 200)
        results.withUnsafeMutableBufferPointer { buffer in
            let output = buffer
            DispatchQueue.concurrentPerform(iterations: lanes) { _ in
                while true {
                    // Kiểm tra lệnh dừng trước mỗi file, để file lớn không giữ cả lô.
                    guard stop?.isStopped != true else { return }
                    lock.lock()
                    let item = next
                    next += 1
                    lock.unlock()
                    guard item < items.count else { return }
                    // Giải phóng dữ liệu tạm của từng file ngay, không để dồn tới khi xong cả lượt.
                    autoreleasepool { output[item] = transform(items[item]) }
                    lock.lock()
                    finished += 1
                    let done = finished
                    lock.unlock()
                    if done % step == 0 || done == items.count { progress?(Double(done) / Double(items.count)) }
                }
            }
        }
        return results
    }
}

public enum MediaKind: Sendable {
    case image, video
}

public struct MediaFile: Identifiable, Hashable, Sendable {
    public let url: URL
    public let size: Int64
    public let kind: MediaKind
    public let modified: Date
    public var id: String { url.path }

    public init(url: URL, size: Int64, kind: MediaKind, modified: Date) {
        self.url = url
        self.size = size
        self.kind = kind
        self.modified = modified
    }
}

public enum MediaScanner {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif",
                                               "bmp", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "3gp", "mts"]
    /// Thư mục kết quả do app tạo ra, không quét lại để tránh xử lý chồng.
    public static let outputFolderName = "ZPS Đã nén"

    public static func kind(of url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    /// Liệt kê ảnh và video, bỏ qua file ẩn, gói như Photos Library, symlink và file iCloud chưa tải.
    /// `batch` nhận từng đợt file mới tìm thấy để giao diện hiện dần; dừng giữa chừng thì trả phần đã có.
    public static func files(in root: URL, recursive: Bool = true, stop: StopFlag? = nil,
                             progress: (Int) -> Void = { _ in },
                             batch: (([MediaFile]) -> Void)? = nil) -> [MediaFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                      .contentModificationDateKey, .isDirectoryKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: options, errorHandler: { _, _ in true }) else {
            return []
        }
        var result: [MediaFile] = []
        var pending: [MediaFile] = []
        for case let url as URL in walker {
            if stop?.isStopped == true { break }
            // Lọc theo đuôi trước khi hỏi hệ thống thuộc tính file, phần tốn thời gian nhất khi duyệt.
            let isFolderCandidate = url.pathExtension.isEmpty || url.lastPathComponent == outputFolderName
            guard let kind = kind(of: url) ?? (isFolderCandidate ? .image : nil) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if url.lastPathComponent == outputFolderName { walker.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true, self.kind(of: url) != nil else { continue }
            let file = MediaFile(url: url, size: Int64(values.fileSize ?? 0), kind: kind,
                                 modified: values.contentModificationDate ?? .distantPast)
            result.append(file)
            pending.append(file)
            if pending.count >= 1000 {
                progress(result.count)
                batch?(pending)
                pending = []
            }
        }
        if !pending.isEmpty { batch?(pending) }
        progress(result.count)
        return result
    }

    /// Ngày chụp từ EXIF, sau đó tới metadata của Spotlight, cuối cùng là ngày sửa file.
    public static func captureDate(of file: MediaFile) -> Date {
        if file.kind == .image, let date = exifDate(file.url) { return date }
        if let item = NSMetadataItem(url: file.url),
           let date = item.value(forAttribute: "kMDItemContentCreationDate") as? Date {
            return date
        }
        return file.modified
    }

    static func exifDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let text = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? exif?[kCGImagePropertyExifDateTimeDigitized] as? String
            ?? tiff?[kCGImagePropertyTIFFDateTime] as? String
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    /// Kích thước điểm ảnh đọc từ phần đầu file, không giải mã cả ảnh.
    public static func dimensions(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    static func pixelCount(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return 0 }
        return width * height
    }
}

public struct DuplicateGroup: Identifiable, Sendable {
    public enum Match: Sendable {
        /// Giống nhau từng byte.
        case exact
        /// Nhìn giống nhau nhưng khác file, ví dụ bản đã nén lại hoặc đổi kích thước.
        case similar
    }

    public let files: [MediaFile]
    public let match: Match
    /// Bản nên giữ: độ phân giải cao nhất, rồi dung lượng lớn nhất, rồi cũ nhất.
    public let suggestedKeep: MediaFile
    public var id: String { suggestedKeep.id }

    public var reclaimable: Int64 { files.filter { $0 != suggestedKeep }.reduce(0) { $0 + $1.size } }

    /// Nhóm còn lại sau khi một số file đã được chuyển đi; nil khi không còn đủ hai file để coi là trùng.
    public func removing(_ ids: Set<String>) -> DuplicateGroup? {
        let remaining = files.filter { !ids.contains($0.id) }
        guard remaining.count > 1 else { return nil }
        guard remaining.count != files.count else { return self }
        let keeper = remaining.contains(suggestedKeep) ? suggestedKeep : DuplicateFinder.pickKeeper(remaining)
        return DuplicateGroup(files: remaining, match: match, suggestedKeep: keeper)
    }
}

public enum DuplicateFinder {
    /// Ngưỡng khác biệt tối đa giữa hai dấu vân tay 64 bit để coi là ảnh giống nhau.
    static let similarThreshold = 5

    public static func find(_ files: [MediaFile], includeSimilar: Bool, stop: StopFlag? = nil, index: MediaIndex? = nil,
                            progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) -> [DuplicateGroup] {
        let exactShare = includeSimilar ? 0.3 : 1
        var groups = exactGroups(files, stop: stop, index: index) { progress(exactShare * $0, "Đang so sánh file cùng dung lượng") }
        guard includeSimilar, stop?.isStopped != true else { return sorted(groups) }

        // Mỗi nhóm giống hệt cử một ảnh đại diện, để bản đã thu nhỏ của nó vẫn được tìm ra.
        var representative: [String: Int] = [:]
        var grouped = Set<String>()
        for (index, group) in groups.enumerated() {
            representative[group.suggestedKeep.id] = index
            grouped.formUnion(group.files.map(\.id))
        }
        let images = files.filter { $0.kind == .image && (!grouped.contains($0.id) || representative[$0.id] != nil) }
        let hashes = Parallel.map(images, stop: stop, width: Parallel.diskWidth, progress: { progress(0.3 + 0.65 * $0, "Đang so sánh nội dung ảnh") }) {
            index.differenceHash($0)
        }
        // Dừng giữa chừng vẫn so các ảnh đã đọc xong.
        let prints = zip(images, hashes).compactMap { file, hash in hash.map { (file: file, hash: $0) } }
        progress(0.97, "Đang gom nhóm \(prints.count) ảnh")
        var merged = Set<Int>()
        for members in cluster(prints) {
            var all = members.filter { representative[$0.id] == nil }
            for index in members.compactMap({ representative[$0.id] }) {
                all += groups[index].files
                merged.insert(index)
            }
            groups.append(DuplicateGroup(files: all, match: .similar, suggestedKeep: pickKeeper(all)))
        }
        groups = groups.enumerated().filter { !merged.contains($0.offset) }.map(\.element)
        return sorted(groups)
    }

    static func sorted(_ groups: [DuplicateGroup]) -> [DuplicateGroup] {
        groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    /// File giống hệt: cùng dung lượng, cùng dấu vân tay đầu và cuối, rồi xác nhận bằng băm toàn bộ.
    static func exactGroups(_ files: [MediaFile], stop: StopFlag?, index: MediaIndex? = nil,
                            progress: @escaping @Sendable (Double) -> Void) -> [DuplicateGroup] {
        let candidates = Dictionary(grouping: files.filter { $0.size > 0 }, by: \.size).values
            .filter { $0.count > 1 }.flatMap { $0 }
        let prints = Parallel.map(candidates, stop: stop, width: Parallel.diskWidth, progress: { progress(0.7 * $0) }) {
            index.fingerprint($0)
        }
        let byPrint = Dictionary(grouping: zip(candidates, prints).compactMap { file, print in print.map { (file, $0) } },
                                 by: { "\($0.0.size):\($0.1)" })
            .values.map { $0.map(\.0) }.filter { $0.count > 1 }

        // File nhỏ đã được đọc trọn khi lấy dấu vân tay; file lớn mới cần băm lại toàn bộ cho chắc.
        let needFull = byPrint.filter { $0[0].size > Int64(fingerprintChunk * 2) }.flatMap { $0 }
        let full = Parallel.map(needFull, stop: stop, width: Parallel.diskWidth, progress: { progress(0.7 + 0.3 * $0) }) {
            index.fullHash($0)
        }
        let fullHash = Dictionary(uniqueKeysWithValues: zip(needFull.map(\.id), full).compactMap { id, hash in hash.map { (id, $0) } })

        var groups: [DuplicateGroup] = []
        for members in byPrint {
            let confirmed: [[MediaFile]]
            if members[0].size > Int64(fingerprintChunk * 2) {
                confirmed = Dictionary(grouping: members.filter { fullHash[$0.id] != nil }, by: { fullHash[$0.id]! })
                    .values.filter { $0.count > 1 }.map { $0 }
            } else {
                confirmed = [members]
            }
            for group in confirmed {
                groups.append(DuplicateGroup(files: group, match: .exact, suggestedKeep: pickKeeper(group)))
            }
        }
        return groups
    }

    static let fingerprintChunk = 64 * 1024

    /// Băm 64 KB đầu và 64 KB cuối, đủ để loại gần như mọi cặp khác nhau mà không phải đọc hết file.
    static func quickFingerprint(_ file: MediaFile) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: fingerprintChunk) else { return nil }
        hasher.update(data: head)
        if file.size > Int64(fingerprintChunk * 2) {
            guard (try? handle.seek(toOffset: UInt64(file.size) - UInt64(fingerprintChunk))) != nil,
                  let tail = try? handle.read(upToCount: fingerprintChunk) else { return nil }
            hasher.update(data: tail)
        } else if let rest = try? handle.readToEnd() {
            hasher.update(data: rest)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func pickKeeper(_ files: [MediaFile]) -> MediaFile {
        let pixels = Dictionary(uniqueKeysWithValues: files.map { ($0.id, MediaScanner.pixelCount($0.url)) })
        return files.max { a, b in
            if pixels[a.id] != pixels[b.id] { return pixels[a.id, default: 0] < pixels[b.id, default: 0] }
            if a.size != b.size { return a.size < b.size }
            return isLessPreferred(a, b)
        }!
    }

    /// Hai bản ngang nhau về chất lượng: giữ bản không mang tên bản sao, rồi bản cũ hơn, rồi đường dẫn ngắn hơn.
    public static func isLessPreferred(_ a: MediaFile, _ b: MediaFile) -> Bool {
        let copyA = looksLikeCopy(a.url.lastPathComponent)
        let copyB = looksLikeCopy(b.url.lastPathComponent)
        if copyA != copyB { return copyA }
        if a.modified != b.modified { return a.modified > b.modified }
        if a.url.path.count != b.url.path.count { return a.url.path.count > b.url.path.count }
        return a.url.path > b.url.path
    }

    /// Tên kiểu "anh copy.jpg", "anh (1).jpg", "anh - Copy.jpg", "anh-1.jpg".
    public static func looksLikeCopy(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension.lowercased()
        return stem.hasSuffix(" copy") || stem.contains(" copy ") || stem.hasSuffix("- copy")
            || stem.range(of: #"(\s\(\d+\)|-\d)$"#, options: .regularExpression) != nil
            || stem.range(of: #"\scopy\s\d+$"#, options: .regularExpression) != nil
    }

    /// File lớn hơn mức này được so bằng mẫu rải đều thay vì đọc hết.
    static let sampledThreshold: Int64 = 256 * 1024 * 1024
    static let sampleCount = 32

    static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // Mỗi đoạn 1 MB được giải phóng ngay sau khi băm, bộ nhớ không phình theo dung lượng file.
            let more: Bool = autoreleasepool {
                guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }
            if !more { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Mã nội dung: file nhỏ băm toàn bộ; file lớn băm 32 đoạn 64 KB rải đều, chỉ đọc khoảng 2 MB.
    static func contentHash(_ file: MediaFile) -> String? {
        guard file.size > sampledThreshold else { return sha256(file.url) }
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let span = UInt64(file.size) - UInt64(fingerprintChunk)
        for sample in 0..<sampleCount {
            let ok: Bool = autoreleasepool {
                let offset = span * UInt64(sample) / UInt64(sampleCount - 1)
                guard (try? handle.seek(toOffset: offset)) != nil,
                      let data = try? handle.read(upToCount: fingerprintChunk) else { return false }
                hasher.update(data: data)
                return true
            }
            if !ok { return nil }
        }
        return "s" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// dHash: thu nhỏ còn 9x8 điểm xám, mỗi bit cho biết điểm bên trái sáng hơn điểm bên phải.
    static func differenceHash(_ url: URL) -> UInt64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 64,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 9, height: 8, bitsPerComponent: 8,
                                          bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        guard drawn else { return nil }
        var hash: UInt64 = 0
        for row in 0..<8 {
            for column in 0..<8 where pixels[row * 9 + column] > pixels[row * 9 + column + 1] {
                hash |= 1 << UInt64(row * 8 + column)
            }
        }
        return hash
    }

    /// Gom các ảnh có dấu vân tay gần nhau, ảnh A giống B và B giống C thì cả ba chung nhóm.
    static func cluster(_ prints: [(file: MediaFile, hash: UInt64)]) -> [[MediaFile]] {
        var parent = Array(prints.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        for i in prints.indices {
            for j in (i + 1)..<prints.count
            where (prints[i].hash ^ prints[j].hash).nonzeroBitCount <= similarThreshold {
                parent[root(j)] = root(i)
            }
        }
        return Dictionary(grouping: prints.indices, by: root).values
            .filter { $0.count > 1 }
            .map { $0.map { prints[$0].file } }
    }
}

/// Thao tác chung cho các tính năng ảnh và video.
public enum MediaFiles {
    /// Chuyển vào Thùng rác; ảnh và video là dữ liệu cá nhân nên không bao giờ xoá hẳn.
    public static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Tên chưa tồn tại: "anh.jpg", "anh (1).jpg", "anh (2).jpg"…
    public static func uniqueURL(_ url: URL, reserved: Set<String> = []) -> URL {
        let fm = FileManager.default
        var candidate = url
        var counter = 1
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        while fm.fileExists(atPath: candidate.path) || reserved.contains(candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    static func copyDates(from source: URL, to target: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) else { return }
        var dates: [FileAttributeKey: Any] = [:]
        dates[.creationDate] = attributes[.creationDate]
        dates[.modificationDate] = attributes[.modificationDate]
        try? FileManager.default.setAttributes(dates, ofItemAtPath: target.path)
    }

    /// Đường dẫn kết quả trong thư mục "ZPS Đã nén", giữ nguyên cấu trúc thư mục con.
    static func outputURL(for source: URL, root: URL, newExtension: String?) -> URL {
        let rootPath = root.standardizedFileURL.path
        var relative = source.standardizedFileURL.path
        if relative.hasPrefix(rootPath + "/") { relative.removeFirst(rootPath.count + 1) }
        var url = root.appendingPathComponent(MediaScanner.outputFolderName).appendingPathComponent(relative)
        if let newExtension { url = url.deletingPathExtension().appendingPathExtension(newExtension) }
        return url
    }
}
