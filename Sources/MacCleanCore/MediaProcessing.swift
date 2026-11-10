@preconcurrency import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct CompressionResult: Identifiable, Sendable {
    public let source: URL
    public let output: URL?
    public let before: Int64
    public let after: Int64
    /// Lý do không nén, ví dụ kết quả không nhỏ hơn bản gốc.
    public let skipped: String?
    public var id: String { source.path }

    public var saved: Int64 { output == nil ? 0 : max(0, before - after) }
}

public enum MediaError: LocalizedError {
    case unreadable, unsupported(String), failed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "Không đọc được file"
        case .unsupported(let reason): return reason
        case .failed(let reason): return reason
        }
    }
}

/// Bản nén chỉ được dùng khi nhỏ hơn bản gốc ít nhất mức này.
let minimumSaving = 0.05

/// Thay bản gốc bằng bản nén: bản gốc vào Thùng rác trước, rồi mới đưa bản nén về đúng chỗ.
func replaceOriginal(_ source: URL, with temp: URL, newExtension: String) throws -> URL {
    let target = MediaFiles.uniqueURL(source.deletingPathExtension().appendingPathExtension(newExtension),
                                      reserved: [])
    let finalURL = newExtension.lowercased() == source.pathExtension.lowercased() ? source : target
    try MediaFiles.trash(source)
    try FileManager.default.moveItem(at: temp, to: finalURL)
    return finalURL
}

public struct ImageCompressionOptions: Sendable {
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case keep = "Giữ định dạng"
        case jpeg = "JPEG"
        case heic = "HEIC"
        public var id: String { rawValue }
    }

    public var quality: Double
    /// Cạnh dài tối đa, nil là giữ nguyên kích thước.
    public var maxDimension: Int?
    public var format: Format
    public var replaceOriginal: Bool

    public init(quality: Double = 0.75, maxDimension: Int? = nil, format: Format = .keep, replaceOriginal: Bool = false) {
        self.quality = quality
        self.maxDimension = maxDimension
        self.format = format
        self.replaceOriginal = replaceOriginal
    }
}

public enum ImageCompressor {
    static let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf"]

    public static var supportsHEIC: Bool {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains(UTType.heic.identifier)
    }

    public static func compress(_ file: MediaFile, options: ImageCompressionOptions, root: URL) -> CompressionResult {
        do {
            return try perform(file, options: options, root: root)
        } catch {
            return CompressionResult(source: file.url, output: nil, before: file.size, after: file.size,
                                     skipped: error.localizedDescription)
        }
    }

    static func perform(_ file: MediaFile, options: ImageCompressionOptions, root: URL) throws -> CompressionResult {
        let ext = file.url.pathExtension.lowercased()
        if rawExtensions.contains(ext) { throw MediaError.unsupported("Ảnh RAW, giữ nguyên để không mất dữ liệu gốc") }
        if ext == "gif" { throw MediaError.unsupported("GIF có thể là ảnh động, giữ nguyên") }
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { throw MediaError.unreadable }
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false

        let type: UTType
        switch options.format {
        case .jpeg:
            if hasAlpha { throw MediaError.unsupported("Ảnh có nền trong suốt, JPEG sẽ làm mất nền") }
            type = .jpeg
        case .heic:
            guard supportsHEIC else { throw MediaError.unsupported("Máy không hỗ trợ ghi HEIC") }
            type = .heic
        case .keep:
            if ext == "png" || ext == "tif" || ext == "tiff" || ext == "bmp" {
                throw MediaError.unsupported("Định dạng không nén có mất dữ liệu; chọn JPEG hoặc HEIC để nén")
            }
            type = UTType(filenameExtension: ext) ?? .jpeg
        }

        let image: CGImage?
        if let maxDimension = options.maxDimension {
            let thumbnail: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                              kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                                              kCGImageSourceCreateThumbnailWithTransform: true]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary)
            // Ảnh thu nhỏ đã được xoay đúng chiều nên bỏ cờ xoay cũ.
            properties[kCGImagePropertyOrientation] = 1
            var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
            properties.removeValue(forKey: kCGImagePropertyPixelWidth)
            properties.removeValue(forKey: kCGImagePropertyPixelHeight)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { throw MediaError.unreadable }
        properties[kCGImageDestinationLossyCompressionQuality] = options.quality

        // Giữ đuôi gốc khi định dạng không đổi, để .jpg không thành .jpeg.
        let sourceType = UTType(filenameExtension: ext)
        let newExtension = sourceType.map { $0.conforms(to: type) } == true ? file.url.pathExtension
            : type.preferredFilenameExtension ?? ext
        let finalOutput = options.replaceOriginal
            ? file.url
            : MediaFiles.outputURL(for: file.url, root: root, newExtension: newExtension)
        try FileManager.default.createDirectory(at: finalOutput.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let temp = finalOutput.deletingLastPathComponent()
            .appendingPathComponent(".zps-\(UUID().uuidString).\(newExtension)")
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type.identifier as CFString, 1, nil) else {
            throw MediaError.failed("Không tạo được file kết quả")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temp)
            throw MediaError.failed("Ghi ảnh thất bại")
        }
        return try finish(file, temp: temp, newExtension: newExtension, options: options, root: root)
    }

    private static func finish(_ file: MediaFile, temp: URL, newExtension: String,
                               options: ImageCompressionOptions, root: URL) throws -> CompressionResult {
        let after = Int64((try? temp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard after > 0, Double(after) < Double(file.size) * (1 - minimumSaving) else {
            try? FileManager.default.removeItem(at: temp)
            return CompressionResult(source: file.url, output: nil, before: file.size, after: file.size,
                                     skipped: "Bản nén không nhỏ hơn đáng kể, giữ bản gốc")
        }
        MediaFiles.copyDates(from: file.url, to: temp)
        let output: URL
        if options.replaceOriginal {
            output = try replaceOriginal(file.url, with: temp, newExtension: newExtension)
        } else {
            output = MediaFiles.uniqueURL(MediaFiles.outputURL(for: file.url, root: root, newExtension: newExtension))
            try FileManager.default.moveItem(at: temp, to: output)
        }
        return CompressionResult(source: file.url, output: output, before: file.size, after: after, skipped: nil)
    }
}

public enum VideoQuality: String, CaseIterable, Identifiable, Sendable {
    case hevcOriginal = "HEVC, giữ độ phân giải"
    case hevc1080 = "HEVC 1080p"
    case h264720 = "H.264 720p, tương thích rộng"
    public var id: String { rawValue }

    var preset: String {
        switch self {
        case .hevcOriginal: return AVAssetExportPresetHEVCHighestQuality
        case .hevc1080: return AVAssetExportPresetHEVC1920x1080
        case .h264720: return AVAssetExportPreset1280x720
        }
    }
}

/// Nén video bằng bộ mã hoá có sẵn của macOS, dùng được phần cứng của máy.
public final class VideoCompressor: @unchecked Sendable {
    private let lock = NSLock()
    private var session: AVAssetExportSession?
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        let current = session
        lock.unlock()
        current?.cancelExport()
    }

    public func compress(_ file: MediaFile, quality: VideoQuality, replaceOriginal: Bool, root: URL,
                         progress: @escaping @Sendable (Double) -> Void) async -> CompressionResult {
        do {
            return try await perform(file, quality: quality, replaceOriginal: replaceOriginal, root: root,
                                     progress: progress)
        } catch {
            return CompressionResult(source: file.url, output: nil, before: file.size, after: file.size,
                                     skipped: error.localizedDescription)
        }
    }

    private func perform(_ file: MediaFile, quality: VideoQuality, replaceOriginal: Bool, root: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> CompressionResult {
        let asset = AVURLAsset(url: file.url)
        guard try await asset.load(.isExportable) else { throw MediaError.unsupported("Video không xuất lại được") }
        guard let export = AVAssetExportSession(asset: asset, presetName: quality.preset) else {
            throw MediaError.unsupported("Video không hợp với chất lượng đã chọn")
        }
        let isMP4 = ["mp4", "m4v"].contains(file.url.pathExtension.lowercased())
        let type: AVFileType = isMP4 && export.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        let newExtension = type == .mp4 ? "mp4" : "mov"
        let finalOutput = replaceOriginal ? file.url : MediaFiles.outputURL(for: file.url, root: root,
                                                                            newExtension: newExtension)
        try FileManager.default.createDirectory(at: finalOutput.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let temp = finalOutput.deletingLastPathComponent().appendingPathComponent(".zps-\(UUID().uuidString).\(newExtension)")
        export.outputURL = temp
        export.outputFileType = type
        export.shouldOptimizeForNetworkUse = true
        // Giữ ngày quay và vị trí để video vẫn đúng chỗ trong thư viện ảnh.
        export.metadata = try await asset.load(.metadata)

        lock.lock()
        if cancelled {
            lock.unlock()
            throw MediaError.failed("Đã huỷ")
        }
        session = export
        lock.unlock()
        defer {
            lock.lock()
            session = nil
            lock.unlock()
        }

        let ticker = Task {
            while !Task.isCancelled {
                progress(Double(export.progress))
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        ticker.cancel()

        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: temp)
            if export.status == .cancelled { throw MediaError.failed("Đã huỷ") }
            throw MediaError.failed(export.error?.localizedDescription ?? "Nén video thất bại")
        }
        progress(1)
        let after = Int64((try? temp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard after > 0, Double(after) < Double(file.size) * (1 - minimumSaving) else {
            try? FileManager.default.removeItem(at: temp)
            return CompressionResult(source: file.url, output: nil, before: file.size, after: file.size,
                                     skipped: "Bản nén không nhỏ hơn đáng kể, giữ bản gốc")
        }
        MediaFiles.copyDates(from: file.url, to: temp)
        let output: URL
        if replaceOriginal {
            output = try MacCleanCore.replaceOriginal(file.url, with: temp, newExtension: newExtension)
        } else {
            output = MediaFiles.uniqueURL(finalOutput)
            try FileManager.default.moveItem(at: temp, to: output)
        }
        return CompressionResult(source: file.url, output: output, before: file.size, after: after, skipped: nil)
    }
}

public struct OrganizeMove: Codable, Sendable {
    public let from: URL
    public let to: URL
}

public enum OrganizeScheme: String, CaseIterable, Identifiable, Sendable {
    case yearMonth = "Năm / Tháng"
    case year = "Năm"
    case yearMonthDay = "Năm / Tháng / Ngày"
    public var id: String { rawValue }

    func folder(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", parts.year ?? 0)
        let month = String(format: "%02d", parts.month ?? 0)
        let day = String(format: "%02d", parts.day ?? 0)
        switch self {
        case .year: return year
        case .yearMonth: return "\(year)/\(year)-\(month)"
        case .yearMonthDay: return "\(year)/\(year)-\(month)/\(year)-\(month)-\(day)"
        }
    }
}

/// Sắp xếp ảnh vào thư mục theo ngày chụp, có lưu lại để hoàn tác.
public enum PhotoOrganizer {
    public static func plan(_ files: [MediaFile], root: URL, scheme: OrganizeScheme, stop: StopFlag? = nil,
                            index: MediaIndex? = nil, progress: ((Double) -> Void)? = nil) -> [OrganizeMove] {
        // Đọc ngày chụp song song; file chưa đọc kịp khi bị dừng thì không đưa vào kế hoạch.
        let dates = Parallel.map(files, stop: stop, width: Parallel.diskWidth, progress: progress) { index.captureDate($0) }
        var reserved = Set<String>()
        var moves: [OrganizeMove] = []
        for (file, date) in zip(files, dates) {
            guard let date else { continue }
            let folder = root.appendingPathComponent(scheme.folder(for: date))
            if file.url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { continue }
            let target = MediaFiles.uniqueURL(folder.appendingPathComponent(file.url.lastPathComponent),
                                              reserved: reserved)
            reserved.insert(target.path)
            moves.append(OrganizeMove(from: file.url, to: target))
        }
        return moves
    }

    /// Thực hiện kế hoạch. Chép thì bản gốc giữ nguyên; chuyển thì lưu danh sách để hoàn tác.
    public static func apply(_ moves: [OrganizeMove], copy: Bool,
                             progress: (Double) -> Void = { _ in }) -> (done: [OrganizeMove], failures: [String]) {
        let fm = FileManager.default
        var done: [OrganizeMove] = []
        var failures: [String] = []
        for (index, move) in moves.enumerated() {
            progress(Double(index) / Double(max(1, moves.count)))
            do {
                try fm.createDirectory(at: move.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Không bao giờ ghi đè: tên đích có thể vừa bị chiếm sau lúc lập kế hoạch.
                let target = MediaFiles.uniqueURL(move.to)
                if copy { try fm.copyItem(at: move.from, to: target) } else { try fm.moveItem(at: move.from, to: target) }
                done.append(OrganizeMove(from: move.from, to: target))
            } catch {
                failures.append("\(move.from.lastPathComponent): \(error.localizedDescription)")
            }
        }
        progress(1)
        return (done, failures)
    }

    /// Đưa file về chỗ cũ. Không ghi đè nếu ở chỗ cũ đã có file khác.
    public static func undo(_ moves: [OrganizeMove], copied: Bool) -> [String] {
        let fm = FileManager.default
        var failures: [String] = []
        for move in moves.reversed() {
            do {
                if copied {
                    try MediaFiles.trash(move.to)
                } else {
                    guard !fm.fileExists(atPath: move.from.path) else {
                        failures.append("\(move.from.lastPathComponent): chỗ cũ đã có file khác")
                        continue
                    }
                    try fm.createDirectory(at: move.from.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: move.to, to: move.from)
                }
            } catch {
                failures.append("\(move.to.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return failures
    }
}
