@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MacCleanCore

final class MediaTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Ảnh có hoạ tiết và nhiễu để JPEG không quá nhỏ; `seed` khác thì hoạ tiết khác.
    private func pattern(width: Int, height: Int, seed: Int, alpha: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                                                  : CGImageAlphaInfo.noneSkipLast.rawValue)!
        var generator = SystemRandomNumberGenerator()
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let base = seed == 0 ? Double(x) / Double(width) : Double(y) / Double(height)
                let noise = Double(UInt8.random(in: 0...40, using: &generator)) / 255
                context.setFillColor(red: base, green: 1 - base, blue: noise + (seed == 2 ? 0.5 : 0),
                                     alpha: alpha && x < width / 2 ? 0.3 : 1)
                context.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        return context.makeImage()!
    }

    @discardableResult
    private func writeImage(_ name: String, width: Int = 1600, height: Int = 1200, seed: Int = 0,
                            type: UTType = .jpeg, quality: Double = 1, date: String? = nil, alpha: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let date { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: date] }
        CGImageDestinationAddImage(destination, pattern(width: width, height: height, seed: seed, alpha: alpha),
                                   properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func files() -> [MediaFile] { MediaScanner.files(in: root) }

    func testScannerSkipsHiddenPackagesAndOwnOutput() throws {
        try writeImage("a.jpg")
        try writeImage(".hidden.jpg")
        try writeImage("Photos Library.photoslibrary/originals/b.jpg")
        try writeImage("\(MediaScanner.outputFolderName)/c.jpg")
        try Data("x".utf8).write(to: root.appendingPathComponent("note.txt"))
        XCTAssertEqual(files().map(\.url.lastPathComponent), ["a.jpg"])
    }

    func testExactAndSimilarDuplicatesKeepBestCopy() throws {
        let original = try writeImage("trip/original.jpg", seed: 0)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("backup"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: root.appendingPathComponent("backup/original copy.jpg"))
        // Cùng ảnh nhưng thu nhỏ và nén mạnh: phải được nhận là "nhìn giống".
        let source = CGImageSourceCreateWithURL(original as CFURL, nil)!
        let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary)!
        let smallURL = root.appendingPathComponent("chat/small.jpg")
        try FileManager.default.createDirectory(at: smallURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = CGImageDestinationCreateWithURL(smallURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
        CGImageDestinationFinalize(destination)
        try writeImage("other.jpg", seed: 1)

        let exactOnly = DuplicateFinder.find(files(), includeSimilar: false)
        XCTAssertEqual(exactOnly.count, 1)
        XCTAssertEqual(exactOnly[0].match, .exact)
        XCTAssertEqual(exactOnly[0].files.count, 2)

        let all = DuplicateFinder.find(files(), includeSimilar: true)
        let similar = try XCTUnwrap(all.first { $0.match == .similar })
        XCTAssertTrue(similar.files.contains { $0.url.lastPathComponent == "small.jpg" })
        XCTAssertEqual(similar.files.count, 3, "Bản sao giống hệt và bản thu nhỏ chung một nhóm")
        XCTAssertEqual(all.count, 1)
        XCTAssertFalse(all.flatMap(\.files).contains { $0.url.lastPathComponent == "other.jpg" })
        XCTAssertNotEqual(similar.suggestedKeep.url.lastPathComponent, "small.jpg")
    }

    func testImageCompressionKeepsOriginalAndExif() throws {
        let url = try writeImage("photos/big.jpg", date: "2021:07:15 10:30:00")
        let file = try XCTUnwrap(files().first)
        let result = ImageCompressor.compress(file, options: ImageCompressionOptions(quality: 0.6, maxDimension: 800),
                                              root: root)
        let output = try XCTUnwrap(result.output, result.skipped ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(output.path, root.appendingPathComponent("\(MediaScanner.outputFolderName)/photos/big.jpg").path)
        XCTAssertLessThan(result.after, result.before)
        XCTAssertEqual(MediaScanner.exifDate(output), MediaScanner.exifDate(url))
        XCTAssertEqual(MediaScanner.pixelCount(output), 800 * 600)
    }

    func testImageCompressionSkipsUnsafeInputs() throws {
        try writeImage("logo.png", width: 400, height: 300, type: .png, alpha: true)
        try writeImage("already.jpg", quality: 0.3)
        for file in files() {
            let keep = ImageCompressor.compress(file, options: ImageCompressionOptions(quality: 0.9), root: root)
            XCTAssertNil(keep.output, file.url.lastPathComponent)
            XCTAssertNotNil(keep.skipped)
        }
        let png = try XCTUnwrap(files().first { $0.url.pathExtension == "png" })
        let jpeg = ImageCompressor.compress(png, options: ImageCompressionOptions(format: .jpeg), root: root)
        XCTAssertNil(jpeg.output, "JPEG làm mất nền trong suốt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(MediaScanner.outputFolderName + "/logo.jpg").path))
    }

    func testOrganizeByCaptureDateNeverOverwritesAndUndoes() throws {
        let first = try writeImage("inbox/IMG_1.jpg", width: 200, height: 150, date: "2024:03:05 08:00:00")
        try writeImage("inbox/sub/IMG_1.jpg", width: 200, height: 150, seed: 1, date: "2024:03:20 08:00:00")
        try writeImage("2024/2024-03/keep.jpg", width: 200, height: 150, date: "2024:03:01 08:00:00")

        let plan = PhotoOrganizer.plan(files(), root: root, scheme: .yearMonth)
        XCTAssertEqual(plan.count, 2, "Ảnh đã đúng chỗ thì không chuyển")
        XCTAssertEqual(Set(plan.map(\.to.lastPathComponent)), ["IMG_1.jpg", "IMG_1 (1).jpg"])

        let result = PhotoOrganizer.apply(plan, copy: false)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        let folder = root.appendingPathComponent("2024/2024-03")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                       ["IMG_1 (1).jpg", "IMG_1.jpg", "keep.jpg"])

        XCTAssertTrue(PhotoOrganizer.undo(result.done, copied: false).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("inbox/sub/IMG_1.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("keep.jpg").path))
    }

    func testReplaceOriginalKeepsNameAndTrashesOriginal() throws {
        let url = try writeImage("Photo.JPG", date: "2022:01:02 03:04:05")
        let file = try XCTUnwrap(files().first)
        let result = ImageCompressor.compress(file, options: ImageCompressionOptions(quality: 0.6, replaceOriginal: true),
                                              root: root)
        XCTAssertEqual(result.output?.lastPathComponent, "Photo.JPG")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertLessThan(Int64((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0), result.before)
        XCTAssertNotNil(MediaScanner.exifDate(url))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Photo.JPG"])
    }

    func testCopyModeKeepsOriginals() throws {
        let photo = try writeImage("a.jpg", width: 200, height: 150, date: "2023:12:31 23:00:00")
        let result = PhotoOrganizer.apply(PhotoOrganizer.plan(files(), root: root, scheme: .year), copy: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("2023/a.jpg").path))
        XCTAssertEqual(result.done.count, 1)
    }

    /// Video thử: hình nhiễu, bitrate cao để bản nén chắc chắn nhỏ hơn.
    private func writeVideo(_ name: String) async throws -> URL {
        let url = root.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280, AVVideoHeightKey: 720,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 720,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let count = CVPixelBufferGetBytesPerRow(pixels) * 720
            var generator = SystemRandomNumberGenerator()
            for index in stride(from: 0, to: count, by: 4) {
                let value = UInt8.random(in: 0...255, using: &generator)
                base[index] = value
                base[index + 1] = value &+ UInt8(frame)
                base[index + 2] = 128
                base[index + 3] = 255
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    func testVideoCompressionWritesSmallerCopy() async throws {
        let url = try await writeVideo("clip.mov")
        let file = try XCTUnwrap(files().first)
        let result = await VideoCompressor().compress(file, quality: .h264720, replaceOriginal: false, root: root) { _ in }
        let output = try XCTUnwrap(result.output, result.skipped ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertLessThan(result.after, result.before)
        let duration = try await AVURLAsset(url: output).load(.duration)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.1)
    }

    func testKeeperPrefersOriginalNameOverCopies() throws {
        let original = try writeImage("Trip/IMG_101.jpg", width: 300, height: 200)
        for name in ["Zalo/IMG_101 copy.jpg", "Zalo/IMG_101 (1).jpg", "a/IMG_101 copy 2.jpg"] {
            let target = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: original, to: target)
        }
        let group = try XCTUnwrap(DuplicateFinder.find(files(), includeSimilar: false).first)
        XCTAssertEqual(group.files.count, 4)
        XCTAssertEqual(group.suggestedKeep.url.lastPathComponent, "IMG_101.jpg")
        XCTAssertEqual(group.suggestedKeep.url.deletingLastPathComponent().lastPathComponent, "Trip")
        _ = original
        XCTAssertTrue(DuplicateFinder.looksLikeCopy("anh - Copy.jpg"))
        XCTAssertFalse(DuplicateFinder.looksLikeCopy("IMG_2024.jpg"))
        XCTAssertFalse(DuplicateFinder.looksLikeCopy("Copywriting.png"))
    }
}
