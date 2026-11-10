import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

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
    public static func files(in root: URL, recursive: Bool = true,
                             progress: (Int) -> Void = { _ in }) -> [MediaFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                      .contentModificationDateKey, .isDirectoryKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: options, errorHandler: { _, _ in true }) else {
            return []
        }
        var result: [MediaFile] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true, url.lastPathComponent == outputFolderName {
                walker.skipDescendants()
                continue
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let kind = kind(of: url) else { continue }
            result.append(MediaFile(url: url, size: Int64(values.fileSize ?? 0), kind: kind,
                                    modified: values.contentModificationDate ?? .distantPast))
            if result.count % 200 == 0 { progress(result.count) }
        }
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
}

public enum DuplicateFinder {
    /// Ngưỡng khác biệt tối đa giữa hai dấu vân tay 64 bit để coi là ảnh giống nhau.
    static let similarThreshold = 5

    public static func find(_ files: [MediaFile], includeSimilar: Bool,
                            progress: (Double, String) -> Void = { _, _ in }) -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []
        var grouped = Set<String>()
        /// Ảnh đại diện của mỗi nhóm giống hệt, để bản đã thu nhỏ của nó vẫn được tìm ra.
        var representative: [String: Int] = [:]

        let sameSize = Dictionary(grouping: files.filter { $0.size > 0 }, by: \.size).values.filter { $0.count > 1 }
        let candidates = sameSize.flatMap { $0 }
        var hashes: [String: [MediaFile]] = [:]
        for (index, file) in candidates.enumerated() {
            progress(0.6 * Double(index) / Double(max(1, candidates.count)), file.url.lastPathComponent)
            if let digest = sha256(file.url) { hashes[digest, default: []].append(file) }
        }
        for members in hashes.values where members.count > 1 {
            let keeper = pickKeeper(members)
            representative[keeper.id] = groups.count
            groups.append(DuplicateGroup(files: members, match: .exact, suggestedKeep: keeper))
            grouped.formUnion(members.map(\.id))
        }

        if includeSimilar {
            let images = files.filter { $0.kind == .image && (!grouped.contains($0.id) || representative[$0.id] != nil) }
            var prints: [(file: MediaFile, hash: UInt64)] = []
            for (index, file) in images.enumerated() {
                progress(0.6 + 0.35 * Double(index) / Double(max(1, images.count)), file.url.lastPathComponent)
                if let hash = differenceHash(file.url) { prints.append((file, hash)) }
            }
            progress(0.96, "So sánh ảnh")
            var merged = Set<Int>()
            for members in cluster(prints) {
                let exactIndexes = members.compactMap { representative[$0.id] }
                var all = members.filter { representative[$0.id] == nil }
                for index in exactIndexes {
                    all += groups[index].files
                    merged.insert(index)
                }
                groups.append(DuplicateGroup(files: all, match: .similar, suggestedKeep: pickKeeper(all)))
            }
            groups = groups.enumerated().filter { !merged.contains($0.offset) }.map(\.element)
        }
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    static func pickKeeper(_ files: [MediaFile]) -> MediaFile {
        let pixels = Dictionary(uniqueKeysWithValues: files.map { ($0.id, MediaScanner.pixelCount($0.url)) })
        return files.max { a, b in
            if pixels[a.id] != pixels[b.id] { return pixels[a.id, default: 0] < pixels[b.id, default: 0] }
            if a.size != b.size { return a.size < b.size }
            if a.modified != b.modified { return a.modified > b.modified }
            return a.url.path.count > b.url.path.count
        }!
    }

    static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
