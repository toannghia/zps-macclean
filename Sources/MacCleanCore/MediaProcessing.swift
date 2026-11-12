@preconcurrency import AVFoundation
import VideoToolbox
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
    case balanced = "Cân bằng · 1080p HEVC (khuyên dùng)"
    case compact = "Nhỏ gọn · 720p HEVC"
    case high = "Chất lượng cao · giữ độ phân giải HEVC"
    case compatible = "Tương thích · 1080p H.264"
    public var id: String { rawValue }

    /// Cạnh ngắn tối đa của khung hình; nil là giữ nguyên. Không bao giờ phóng to video.
    var maxShortSide: Int? {
        switch self {
        case .balanced, .compatible: return 1080
        case .compact: return 720
        case .high: return nil
        }
    }

    var codec: AVVideoCodecType { self == .compatible ? .h264 : .hevc }

    /// Bitrate hình mục tiêu, theo mức các nền tảng video dùng cho HEVC; H.264 cần gần gấp đôi cho cùng chất lượng.
    public func bitrate(shortSide: Int, frameRate: Double) -> Int {
        let base: Double
        switch shortSide {
        case ..<540: base = 1_000_000
        case ..<800: base = 2_000_000
        case ..<1200: base = 4_000_000
        case ..<1600: base = 8_000_000
        default: base = 16_000_000
        }
        var rate = base * (frameRate > 40 ? 1.5 : 1)
        if self == .high { rate *= 1.5 }
        if codec == .h264 { rate *= 2 }
        return Int(rate)
    }
}

/// Nén video theo bitrate mục tiêu bằng bộ mã hoá phần cứng của Mac. Các mức nén có sẵn của Apple giữ
/// bitrate rất cao nên gần như không nhỏ đi; đặt bitrate như các nền tảng video mới giảm được nhiều lần.
public final class VideoCompressor: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var reader: AVAssetReader?

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        let current = reader
        lock.unlock()
        current?.cancelReading()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
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

    /// Thông số sẽ dùng để nén, tính được trước để ước lượng dung lượng.
    public struct Plan: Sendable {
        public let width: Int
        public let height: Int
        public let bitrate: Int
        public let duration: Double
        public let sourceBitrate: Double
        public let isHDR: Bool

        /// Dung lượng dự kiến gồm hình và tiếng AAC 128 kbps.
        public var estimatedBytes: Int64 { Int64((Double(bitrate) + 128_000) / 8 * duration) }
    }

    public static func plan(for url: URL, quality: VideoQuality) async throws -> Plan {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.unsupported("File không có hình")
        }
        let (natural, frameRate, dataRate, formats) = try await track.load(.naturalSize, .nominalFrameRate,
                                                                            .estimatedDataRate, .formatDescriptions)
        let duration = try await asset.load(.duration).seconds
        let sourceWidth = Int(abs(natural.width)), sourceHeight = Int(abs(natural.height))
        guard sourceWidth > 0, sourceHeight > 0 else { throw MediaError.unreadable }
        let short = min(sourceWidth, sourceHeight)
        let scale = quality.maxShortSide.map { min(1, Double($0) / Double(short)) } ?? 1
        // Bộ mã hoá cần kích thước chẵn.
        func even(_ value: Double) -> Int { max(2, Int(value / 2) * 2) }
        let width = even(Double(sourceWidth) * scale), height = even(Double(sourceHeight) * scale)
        let transfer = formats.first.flatMap {
            CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        }
        let isHDR = transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        return Plan(width: width, height: height,
                    bitrate: quality.bitrate(shortSide: min(width, height), frameRate: Double(frameRate)),
                    duration: duration, sourceBitrate: Double(dataRate), isHDR: isHDR)
    }

    private func perform(_ file: MediaFile, quality: VideoQuality, replaceOriginal: Bool, root: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> CompressionResult {
        if isCancelled { throw MediaError.failed("Đã huỷ") }
        let plan = try await Self.plan(for: file.url, quality: quality)
        // Nén lại một video vốn đã nhẹ chỉ làm giảm chất lượng mà gần như không tiết kiệm được gì.
        if plan.sourceBitrate > 0, Double(plan.bitrate) > plan.sourceBitrate * 0.7 {
            throw MediaError.unsupported("Video đã ở bitrate thấp (\(Int(plan.sourceBitrate / 1_000_000)) Mbps), nén thêm không nhỏ đi đáng kể")
        }

        let asset = AVURLAsset(url: file.url)
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first!
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let (transform, frameRate) = try await videoTrack.load(.preferredTransform, .nominalFrameRate)
        let duration = plan.duration

        let finalOutput = replaceOriginal ? file.url
            : MediaFiles.outputURL(for: file.url, root: root, newExtension: "mp4")
        try FileManager.default.createDirectory(at: finalOutput.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = finalOutput.deletingLastPathComponent().appendingPathComponent(".zps-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temp) }

        let reader = try AVAssetReader(asset: asset)
        // Video HDR được giữ 10 bit để màu không bị bạc; video thường dùng 8 bit cho nhẹ.
        let pixelFormat = plan.isHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                     : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: temp, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        // Giữ ngày quay, vị trí và tên thiết bị.
        writer.metadata = (try? await asset.load(.metadata)) ?? []

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: plan.bitrate,
            AVVideoExpectedSourceFrameRateKey: max(1, Double(frameRate)),
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: true,
        ]
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: plan.isHDR ? AVVideoCodecType.hevc : quality.codec,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
        ]
        if plan.isHDR {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            let formats = try await videoTrack.load(.formatDescriptions)
            if let format = formats.first {
                func value(_ key: CFString) -> Any? { CMFormatDescriptionGetExtension(format, extensionKey: key) }
                videoSettings[AVVideoColorPropertiesKey] = [
                    AVVideoColorPrimariesKey: value(kCMFormatDescriptionExtension_ColorPrimaries) ?? AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: value(kCMFormatDescriptionExtension_TransferFunction) ?? AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: value(kCMFormatDescriptionExtension_YCbCrMatrix) ?? AVVideoYCbCrMatrix_ITU_R_2020,
                ]
            }
        } else if quality.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        videoSettings[AVVideoCompressionPropertiesKey] = compression
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw MediaError.unsupported("Không tạo được luồng hình cho định dạng này") }
        writer.add(videoInput)

        var audioPair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
        if let audioTrack {
            let formats = try await audioTrack.load(.formatDescriptions)
            let basic = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let channels = min(2, max(1, Int(basic?.mChannelsPerFrame ?? 2)))
            let sampleRate = basic.map { $0.mSampleRate > 0 ? $0.mSampleRate : 44_100 } ?? 44_100
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            let pcm: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: channels, AVSampleRateKey: sampleRate, AVChannelLayoutKey: layoutData,
            ]
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcm)
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: channels, AVSampleRateKey: sampleRate,
                AVEncoderBitRateKey: 128_000, AVChannelLayoutKey: layoutData,
            ])
            audioInput.expectsMediaDataInRealTime = false
            if reader.canAdd(audioOutput), writer.canAdd(audioInput) {
                reader.add(audioOutput)
                writer.add(audioInput)
                audioPair = (audioOutput, audioInput)
            }
        }

        lock.lock()
        self.reader = reader
        let stopNow = cancelled
        lock.unlock()
        defer {
            lock.lock()
            self.reader = nil
            lock.unlock()
        }
        if stopNow { throw MediaError.failed("Đã huỷ") }

        guard reader.startReading() else {
            throw MediaError.failed(reader.error?.localizedDescription ?? "Không đọc được video")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw MediaError.failed(writer.error?.localizedDescription ?? "Không ghi được video")
        }
        writer.startSession(atSourceTime: .zero)

        // Mỗi luồng hình và tiếng được bơm trên hàng đợi riêng, chỉ khi bộ mã hoá sẵn sàng nhận thêm.
        let group = DispatchGroup()
        func pump(_ output: AVAssetReaderTrackOutput, into input: AVAssetWriterInput, label: String, reportsProgress: Bool) {
            group.enter()
            let queue = DispatchQueue(label: "vn.zenpos.macclean.\(label)")
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData, !finished {
                    guard let sample = output.copyNextSampleBuffer() else {
                        finished = true
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    if reportsProgress, duration > 0 {
                        progress(min(0.99, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration))
                    }
                    if !input.append(sample) {
                        finished = true
                        reader.cancelReading()
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
        pump(videoOutput, into: videoInput, label: "video", reportsProgress: true)
        if let (audioOutput, audioInput) = audioPair {
            pump(audioOutput, into: audioInput, label: "audio", reportsProgress: false)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }

        if isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            throw MediaError.failed("Đã huỷ")
        }
        if reader.status == .failed || writer.status == .failed {
            writer.cancelWriting()
            throw MediaError.failed(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "Nén video thất bại")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MediaError.failed(writer.error?.localizedDescription ?? "Nén video thất bại")
        }
        progress(1)

        let after = Int64((try? temp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard after > 0, Double(after) < Double(file.size) * (1 - minimumSaving) else {
            return CompressionResult(source: file.url, output: nil, before: file.size, after: file.size,
                                     skipped: "Bản nén không nhỏ hơn đáng kể, giữ bản gốc")
        }
        MediaFiles.copyDates(from: file.url, to: temp)
        let output: URL
        if replaceOriginal {
            output = try MacCleanCore.replaceOriginal(file.url, with: temp, newExtension: "mp4")
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
