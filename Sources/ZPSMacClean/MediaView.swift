import AppKit
import MacCleanCore
import QuickLookThumbnailing
import SwiftUI

@MainActor
final class MediaModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case duplicates = "Ảnh trùng"
        case images = "Nén ảnh"
        case organize = "Sắp xếp ảnh"
        case videos = "Nén video"
        var id: String { rawValue }
    }

    @Published var tool = Tool.duplicates
    @Published var folder: URL? {
        didSet {
            UserDefaults.standard.set(folder?.path, forKey: "mediaFolder")
            reset()
            loadLastScan()
        }
    }
    @Published var recursive = true
    @Published var isBusy = false
    @Published var progress = WorkProgress()
    @Published var notice: String?

    @Published var includeSimilar = true
    @Published var duplicates: [DuplicateGroup] = [] { didSet { groupPage = min(groupPage, groupPageCount - 1) } }
    /// Trang nhóm trùng đang xem, mỗi trang vài chục nhóm để danh sách hàng nghìn nhóm vẫn cuộn mượt.
    @Published var groupPage = 0
    /// Lượt tìm trùng gần nhất bị dừng giữa chừng, còn phần chưa quét.
    @Published var duplicatesPartial = false
    let groupsPerPage = 50

    var groupPageCount: Int { max(1, (duplicates.count + groupsPerPage - 1) / groupsPerPage) }

    var pageGroups: ArraySlice<DuplicateGroup> {
        let start = min(groupPage * groupsPerPage, duplicates.count)
        return duplicates[start ..< min(start + groupsPerPage, duplicates.count)]
    }
    /// Các file người dùng đã đánh dấu để chuyển vào Thùng rác.
    @Published var marked = Set<String>()

    @Published var imageOptions = ImageCompressionOptions()
    @Published var videoQuality = VideoQuality.hevc1080
    @Published var replaceVideos = false
    @Published var rows: [MediaRow] = [] {
        didSet {
            if rows.count != rowIndex.count {
                rowIndex = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            }
            refreshVisible()
        }
    }
    @Published var rowFilter = RowFilter.all { didSet { page = 0; refreshVisible() } }
    @Published var largeMB = 3 { didSet { page = 0; refreshVisible() } }
    @Published var sortOrder = [KeyPathComparator(\MediaRow.size, order: .reverse)] { didSet { page = 0; refreshVisible() } }
    /// Trang đang xem, tính từ 0. Bảng chỉ vẽ một trang để danh sách hàng chục nghìn file vẫn nhẹ.
    @Published var page = 0
    @Published var pageSize = UserDefaults.standard.integer(forKey: "mediaPageSize") == 0
        ? 200 : UserDefaults.standard.integer(forKey: "mediaPageSize") {
        didSet {
            UserDefaults.standard.set(pageSize, forKey: "mediaPageSize")
            page = 0
        }
    }

    var pageCount: Int { max(1, (visibleRows.count + pageSize - 1) / pageSize) }

    var pageRows: ArraySlice<MediaRow> {
        let start = min(page * pageSize, visibleRows.count)
        return visibleRows[start ..< min(start + pageSize, visibleRows.count)]
    }

    func selectPage() {
        selection.formUnion(pageRows.map(\.id))
    }
    @Published var selection = Set<String>()
    /// Hàng đang hiện sau khi lọc và sắp xếp; tính sẵn để bảng hàng chục nghìn dòng không tính lại mỗi lần vẽ.
    @Published private(set) var visibleRows: [MediaRow] = []
    @Published var results: [CompressionResult] = []

    @Published var scheme = OrganizeScheme.yearMonth
    @Published var copyInsteadOfMove = false
    @Published var plan: [OrganizeMove] = []
    @Published var lastOrganize: (moves: [OrganizeMove], copied: Bool)?

    private let video = VideoCompressor()
    /// Thư mục và tuỳ chọn của lượt đang chạy, đọc được từ luồng nền.
    nonisolated(unsafe) private var scope: (folder: URL, recursive: Bool)?
    /// Đọc được từ luồng nền để các vòng lặp quét và nén dừng giữa chừng.
    nonisolated let stopFlag = StopFlag()
    nonisolated let index = MediaIndex.shared
    /// Lần quét gần nhất của thư mục đang chọn, đọc từ chỉ mục.
    @Published var lastScan: MediaIndex.FolderScan?
    /// Số file của lượt quét đang chạy, ghi vào chỉ mục khi xong.
    nonisolated(unsafe) private var scannedFiles = 0
    @Published private(set) var stopped = false
    /// Đã bấm Dừng, đang chờ các luồng đọc file kết thúc.
    @Published private(set) var stopping = false
    private var rowIndex: [String: Int] = [:]

    init() {
        if let path = UserDefaults.standard.string(forKey: "mediaFolder"),
           FileManager.default.fileExists(atPath: path) {
            folder = URL(fileURLWithPath: path)
        }
    }

    var markedSize: Int64 {
        duplicates.flatMap(\.files).filter { marked.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    /// Chỉ đọc thông tin lần quét trước, không quét gì.
    func loadLastScan() {
        guard let folder else { return lastScan = nil }
        Task.detached(priority: .utility) { [index] in
            let last = index.lastScan(of: folder)
            await MainActor.run { self.lastScan = last }
        }
    }

    func reset() {
        duplicates = []
        marked = []
        rows = []
        selection = []
        results = []
        plan = []
        notice = nil
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Chọn"
        if panel.runModal() == .OK, let url = panel.url {
            if url.pathExtension == "photoslibrary" {
                notice = "Không xử lý trực tiếp thư viện Photos. Hãy xuất ảnh ra một thư mục rồi chọn thư mục đó."
                return
            }
            folder = url
        }
    }

    private func run(_ phase: String, _ work: @escaping @Sendable (MediaModel) async -> Void) {
        guard !isBusy, let folder else { return }
        let recursive = recursive
        scope = (folder, recursive)
        scannedFiles = 0
        isBusy = true
        stopFlag.reset()
        stopping = false
        stopped = false
        notice = nil
        progress = WorkProgress(phase: phase)
        let watchdog = memoryWatchdog()
        Task.detached(priority: .userInitiated) { [self] in
            self.index.loadIfNeeded()
            await work(self)
            watchdog.cancel()
            let overLimit = await watchdog.value
            // Lưu cả khi bị dừng: phần đã đọc được dùng lại cho lần sau.
            if !self.stopFlag.isStopped, self.scannedFiles > 0 {
                self.index.recordScan(of: folder, files: self.scannedFiles)
            }
            let last = self.index.lastScan(of: folder)
            // Hiện kết quả trước; chỉ mục có thể hàng chục MB nên được lưu ở nền sau đó.
            defer { Task.detached(priority: .utility) { self.index.save() } }
            await MainActor.run {
                self.isBusy = false
                self.stopping = false
                self.lastScan = last
                self.refreshVisible()
                if let overLimit {
                    self.stopped = true
                    self.notice = "Đã tự dừng vì app dùng tới \(formatBytes(overLimit)) bộ nhớ, để máy không bị treo. Kết quả đến lúc dừng vẫn được giữ và lưu lại; bấm Quét lại để làm tiếp phần còn thiếu."
                }
            }
        }
    }

    /// Mức bộ nhớ tối đa cho một lượt quét: một phần tư RAM của máy, không quá 4 GB.
    nonisolated static let memoryLimit = min(Int64(4) << 30, Int64(ProcessInfo.processInfo.physicalMemory) / 4)

    /// Đo bộ nhớ của chính app mỗi giây; vượt ngưỡng thì dừng lượt quét và trả về mức đã dùng.
    private func memoryWatchdog() -> Task<Int64?, Never> {
        let stop = stopFlag
        return Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if let used = ProcessMonitor.memoryFootprint(getpid()), used > Self.memoryLimit {
                    stop.stop()
                    return used
                }
                try? await Task.sleep(for: .seconds(1))
            }
            return nil
        }
    }

    nonisolated private func report(_ fraction: Double, _ phase: String, _ detail: String = "") {
        Task { @MainActor in
            // Sau khi bấm Dừng giữ nguyên dòng "Đang dừng…" để người dùng biết lệnh đã được nhận.
            guard !self.stopping else { return }
            self.progress = WorkProgress(fraction: fraction, phase: phase, detail: detail)
        }
    }

    /// Chạy ngoài luồng giao diện: thư mục lớn có thể mất vài chục giây để duyệt.
    nonisolated private func listFiles(_ kind: MediaKind?, in folder: URL, recursive: Bool,
                                       batch: (([MediaFile]) -> Void)? = nil) -> [MediaFile] {
        let all = MediaScanner.files(in: folder, recursive: recursive, stop: stopFlag, progress: { count in
            self.report(0.05, "Đang tìm file", "Đã tìm thấy \(count) file")
        }, batch: batch.map { send in { found in send(kind.map { kind in found.filter { $0.kind == kind } } ?? found) } })
        return kind.map { kind in all.filter { $0.kind == kind } } ?? all
    }

    // MARK: Ảnh trùng

    func findDuplicates() {
        let similar = includeSimilar
        run("Đang tìm ảnh trùng") { model in
            let files = model.listFiles(nil, in: model.scope!.folder, recursive: model.scope!.recursive)
            model.scannedFiles = files.count
            let groups = DuplicateFinder.find(files, includeSimilar: similar, stop: model.stopFlag, index: model.index) { fraction, phase in
                model.report(fraction, phase, "\(files.count) file")
            }
            let stopped = model.stopFlag.isStopped
            await MainActor.run {
                // Quét tiếp giữ nguyên trang và các file đã tick nếu chúng vẫn còn trong kết quả.
                let page = model.groupPage
                model.duplicates = groups
                model.marked.formIntersection(Set(groups.flatMap { $0.files.map(\.id) }))
                model.groupPage = min(page, model.groupPageCount - 1)
                model.duplicatesPartial = stopped
                model.stopped = stopped
                model.notice = stopped ? "Đã dừng. Đang hiện \(groups.count) nhóm trùng tìm được trước khi dừng; bấm Quét tiếp để làm nốt phần còn lại."
                    : groups.isEmpty ? "Không tìm thấy ảnh hoặc video trùng." : nil
            }
        }
    }

    /// Đánh dấu mọi bản trừ bản tốt nhất của nhóm.
    func markExtras(in group: DuplicateGroup) {
        marked.formUnion(group.files.filter { $0 != group.suggestedKeep }.map(\.id))
    }

    func unmark(_ group: DuplicateGroup) {
        marked.subtract(group.files.map(\.id))
    }

    /// Chỉ các nhóm trên trang đang xem, để duyệt và chọn lần lượt từng trang.
    func markExtrasOnPage() {
        for group in pageGroups { markExtras(in: group) }
    }

    func unmarkPage() {
        for group in pageGroups { unmark(group) }
    }

    var pageHasMarks: Bool {
        pageGroups.contains { group in group.files.contains { marked.contains($0.id) } }
    }

    func markExtrasEverywhere() {
        for group in duplicates { markExtras(in: group) }
    }

    func toggle(_ file: MediaFile, in group: DuplicateGroup) {
        if marked.contains(file.id) {
            marked.remove(file.id)
        } else if group.files.filter({ !marked.contains($0.id) }).count > 1 {
            marked.insert(file.id)
        } else {
            notice = "Mỗi nhóm phải giữ lại ít nhất một bản."
        }
    }

    func trashMarked() {
        let files = duplicates.flatMap(\.files).filter { marked.contains($0.id) }
        run("Đang chuyển vào Thùng rác") { model in
            var failures: [String] = []
            var moved = Set<String>()
            for (index, file) in files.enumerated() {
                model.report(Double(index) / Double(max(1, files.count)), "Đang chuyển vào Thùng rác", file.url.lastPathComponent)
                do {
                    try MediaFiles.trash(file.url)
                    moved.insert(file.id)
                } catch {
                    failures.append("\(file.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            let size = files.filter { moved.contains($0.id) }.reduce(Int64(0)) { $0 + $1.size }
            await MainActor.run {
                // Giữ nguyên danh sách và trang đang xem; chỉ gỡ các file vừa chuyển đi.
                let page = model.groupPage
                model.duplicates = model.duplicates.compactMap { $0.removing(moved) }
                model.marked.subtract(moved)
                model.groupPage = min(page, model.groupPageCount - 1)
                model.notice = failures.isEmpty
                    ? "Đã chuyển \(moved.count) file (\(formatBytes(size))) vào Thùng rác. Đổ Thùng rác để giải phóng dung lượng."
                    : "Đã chuyển \(moved.count) file. Còn \(failures.count) file chưa chuyển được: \(failures.first ?? "")"
            }
        }
    }

    // MARK: Danh sách ảnh, video để nén hoặc xoá

    private var lastRefresh = Date.distantPast
    private var refreshPending = false

    func refreshVisible() {
        if isBusy, Date().timeIntervalSince(lastRefresh) < 1 {
            guard !refreshPending else { return }
            refreshPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.refreshPending = false
                self?.refreshVisible()
            }
            return
        }
        lastRefresh = Date()
        let limit = Int64(largeMB) * 1_000_000
        visibleRows = rows.filter { row in
            switch rowFilter {
            case .all: return true
            case .large: return row.size >= limit
            case .duplicates: return row.copies > 1
            }
        }.sorted(using: sortOrder)
        // Danh sách ngắn lại sau khi lọc hoặc xoá thì không để trang hiện tại vượt quá trang cuối.
        page = min(page, pageCount - 1)
    }

    var selectedRows: [MediaRow] { rows.filter { selection.contains($0.id) } }

    /// Số file đã chọn mà không còn bản nào khác chưa chọn, tức sẽ mất hẳn nếu đổ Thùng rác.
    var selectedLastCopies: Int {
        let chosen = selectedRows
        let remaining = Dictionary(grouping: rows.filter { !selection.contains($0.id) && $0.group != nil }, by: { $0.group! })
        return chosen.filter { row in row.group.map { remaining[$0] == nil } ?? true }.count
    }

    func listCandidates() {
        let kind: MediaKind = tool == .videos ? .video : .image
        rows = []
        selection = []
        results = []
        run("Đang tìm file") { model in
            let stop = model.stopFlag
            // Bảng hiện ngay từng đợt file tìm thấy, chưa có kích thước và nhãn trùng.
            let files = model.listFiles(kind, in: model.scope!.folder, recursive: model.scope!.recursive) { found in
                let fresh = found.map { MediaRow(file: $0, width: 0, height: 0, group: nil, copies: 1) }
                Task { @MainActor in model.append(fresh) }
            }
            model.scannedFiles = files.count
            if !stop.isStopped {
                let groups = DuplicateFinder.find(files, includeSimilar: false, stop: stop, index: model.index) { fraction, phase in
                    model.report(0.1 + 0.3 * fraction, phase, "\(files.count) file")
                }
                await MainActor.run { model.apply(groups) }
            }
            if kind == .image, !stop.isStopped {
                // Đọc kích thước theo từng đợt để bảng cập nhật dần thay vì chờ hết.
                let batches = stride(from: 0, to: files.count, by: 2000).map { Array(files[$0 ..< min(files.count, $0 + 2000)]) }
                for (index, batch) in batches.enumerated() where !stop.isStopped {
                    model.report(0.4 + 0.6 * Double(index) / Double(max(1, batches.count)), "Đang đọc kích thước ảnh",
                                 "\(index * 2000)/\(files.count)")
                    let sizes = Parallel.map(batch, stop: stop) { model.index.dimensions($0) }
                    let update = Dictionary(uniqueKeysWithValues: zip(batch.map(\.id), sizes).compactMap { id, size in
                        size.map { (id, $0) }
                    })
                    await MainActor.run { model.applyDimensions(update) }
                }
            }
            let stopped = stop.isStopped
            await MainActor.run {
                model.stopped = stopped
                model.notice = stopped ? "Đã dừng. Đang hiện \(model.rows.count) file đã quét được; nhãn trùng và kích thước có thể chưa đủ."
                    : model.rows.isEmpty ? "Không có file phù hợp trong thư mục này." : nil
            }
        }
    }

    /// Gom cả đợt rồi gán một lần: gán từng dòng sẽ khiến bảng lọc và sắp xếp lại hàng nghìn lần.
    private func append(_ fresh: [MediaRow]) {
        guard isBusy else { return }
        var updated = rows
        var index = rowIndex
        for row in fresh where index[row.id] == nil {
            index[row.id] = updated.count
            updated.append(row)
        }
        rowIndex = index
        rows = updated
    }

    private func apply(_ groups: [DuplicateGroup]) {
        var updated = rows
        for group in groups {
            for file in group.files {
                if let index = rowIndex[file.id] {
                    updated[index].group = group.id
                    updated[index].copies = group.files.count
                }
            }
        }
        rows = updated
    }

    private func applyDimensions(_ sizes: [String: (width: Int, height: Int)]) {
        var updated = rows
        for (id, size) in sizes {
            if let index = rowIndex[id] {
                updated[index].width = size.width
                updated[index].height = size.height
            }
        }
        rows = updated
    }

    func selectAllVisible() {
        selection = Set(visibleRows.map(\.id))
    }

    /// Chọn các bản thừa trong mỗi nhóm trùng, giữ lại bản lớn nhất.
    func selectExtraCopies() {
        let grouped = Dictionary(grouping: rows.filter { $0.group != nil }, by: { $0.group! })
        selection = Set(grouped.values.flatMap { members in
            members.sorted { a, b in
                if a.pixels != b.pixels { return a.pixels > b.pixels }
                if a.size != b.size { return a.size > b.size }
                return DuplicateFinder.isLessPreferred(b.file, a.file)
            }.dropFirst().map(\.id)
        })
    }

    func trashSelected() {
        let chosen = selectedRows
        run("Đang chuyển vào Thùng rác") { model in
            var failures: [String] = []
            var moved = Set<String>()
            for (index, row) in chosen.enumerated() {
                model.report(Double(index) / Double(max(1, chosen.count)), "Đang chuyển vào Thùng rác", row.name)
                do {
                    try MediaFiles.trash(row.file.url)
                    moved.insert(row.id)
                } catch {
                    failures.append("\(row.name): \(error.localizedDescription)")
                }
            }
            let size = chosen.filter { moved.contains($0.id) }.reduce(Int64(0)) { $0 + $1.size }
            await MainActor.run {
                model.rowIndex = [:]
                model.rows = MediaRow.recount(model.rows.filter { !moved.contains($0.id) })
                model.selection = []
                model.notice = "Đã chuyển \(moved.count) file (\(formatBytes(size))) vào Thùng rác."
                    + (failures.isEmpty ? " Đổ Thùng rác để giải phóng dung lượng." : " \(failures.count) file lỗi: \(failures[0])")
            }
        }
    }

    func compressImages() {
        guard let folder else { return }
        let files = selectedRows.map(\.file)
        let options = imageOptions
        run("Đang nén ảnh") { model in
            var results: [CompressionResult] = []
            for (index, file) in files.enumerated() {
                if model.stopFlag.isStopped { break }
                model.report(Double(index) / Double(max(1, files.count)), "Đang nén ảnh (\(index + 1)/\(files.count))",
                             file.url.lastPathComponent)
                results.append(ImageCompressor.compress(file, options: options, root: folder))
            }
            await model.finishCompression(results)
        }
    }

    func compressVideos() {
        guard let folder else { return }
        let files = selectedRows.map(\.file)
        let quality = videoQuality
        let replace = replaceVideos
        let compressor = video
        run("Đang nén video") { model in
            var results: [CompressionResult] = []
            for (index, file) in files.enumerated() {
                if model.stopFlag.isStopped { break }
                let label = "Đang nén video (\(index + 1)/\(files.count))"
                let result = await compressor.compress(file, quality: quality, replaceOriginal: replace, root: folder) { part in
                    model.report((Double(index) + part) / Double(files.count), label, file.url.lastPathComponent)
                }
                results.append(result)
            }
            await model.finishCompression(results)
        }
    }

    func cancel() {
        guard isBusy, !stopping else { return }
        stopping = true
        progress.phase = "Đang dừng…"
        progress.detail = "Chờ đọc xong các file đang dở và gom kết quả đã quét"
        stopFlag.stop()
        video.cancel()
    }

    private func finishCompression(_ results: [CompressionResult]) {
        self.results = results
        let saved = results.reduce(Int64(0)) { $0 + $1.saved }
        let done = results.filter { $0.output != nil }.count
        notice = "Đã nén \(done)/\(results.count) file, tiết kiệm \(formatBytes(saved))."
            + (stopFlag.isStopped ? " Đã dừng theo yêu cầu." : "")
    }

    // MARK: Sắp xếp

    func makePlan() {
        guard let folder else { return }
        let scheme = scheme
        run("Đang đọc ngày chụp") { model in
            let files = model.listFiles(nil, in: model.scope!.folder, recursive: model.scope!.recursive)
            model.scannedFiles = files.count
            let plan = PhotoOrganizer.plan(files, root: folder, scheme: scheme, stop: model.stopFlag, index: model.index) { fraction in
                model.report(0.1 + 0.9 * fraction, "Đang đọc ngày chụp", "\(files.count) file")
            }
            let stopped = model.stopFlag.isStopped
            await MainActor.run {
                model.plan = plan
                model.stopped = stopped
                model.notice = stopped ? "Đã dừng. Kế hoạch chỉ gồm \(plan.count) file đã đọc được ngày chụp."
                    : plan.isEmpty ? "Ảnh đã được xếp đúng chỗ." : nil
            }
        }
    }

    func applyPlan() {
        let plan = plan
        let copy = copyInsteadOfMove
        run(copy ? "Đang chép ảnh" : "Đang chuyển ảnh") { model in
            let result = PhotoOrganizer.apply(plan, copy: copy) { fraction in
                model.report(fraction, copy ? "Đang chép ảnh" : "Đang chuyển ảnh")
            }
            model.saveManifest(result.done, copied: copy)
            await MainActor.run {
                model.lastOrganize = (result.done, copy)
                model.plan = []
                model.notice = "Đã \(copy ? "chép" : "chuyển") \(result.done.count) file."
                    + (result.failures.isEmpty ? "" : " \(result.failures.count) file lỗi: \(result.failures[0])")
            }
        }
    }

    func undoOrganize() {
        guard let last = lastOrganize else { return }
        run("Đang hoàn tác") { model in
            let failures = PhotoOrganizer.undo(last.moves, copied: last.copied)
            await MainActor.run {
                model.lastOrganize = nil
                model.notice = failures.isEmpty ? "Đã hoàn tác." : "Hoàn tác xong, \(failures.count) file lỗi: \(failures[0])"
            }
        }
    }

    /// Lưu danh sách đã chuyển để còn biết file đi đâu nếu app bị tắt trước khi hoàn tác.
    nonisolated private func saveManifest(_ moves: [OrganizeMove], copied: Bool) {
        guard !moves.isEmpty else { return }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ZPS-MacClean")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "sap-xep-anh-\(stamp)\(copied ? "-chep" : "").json"
        if let data = try? JSONEncoder().encode(moves) {
            try? data.write(to: folder.appendingPathComponent(name))
        }
    }
}

struct MediaView: View {
    @StateObject private var model = MediaModel()
    @State private var confirmation: Confirmation?

    private struct Confirmation: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let action: String
        let perform: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            Divider()
            content
            Divider()
            footer
        }
        .alert(confirmation?.title ?? "", isPresented: Binding(get: { confirmation != nil },
                                                               set: { if !$0 { confirmation = nil } }),
               presenting: confirmation) { item in
            Button(item.action, role: .destructive) { item.perform() }
            Button("Huỷ", role: .cancel) {}
        } message: { Text($0.message) }
        .onChange(of: model.tool) { model.reset() }
        .onAppear { model.loadLastScan() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appTitle).font(Brand.heading(14, "SemiBold")).foregroundStyle(.white).lineLimit(1)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ảnh & Video").font(Brand.heading(13, "SemiBold")).foregroundStyle(.white.opacity(0.75))
                    Text(model.folder?.lastPathComponent ?? "Chưa chọn thư mục")
                        .font(Brand.heading(24)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                    if let folder = model.folder {
                        Text(folder.path).font(.caption).foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                Spacer()
                Button(model.folder == nil ? "Chọn thư mục…" : "Đổi thư mục…") { model.chooseFolder() }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.teal)
                    .disabled(model.isBusy)
            }
            Picker("Công cụ", selection: $model.tool) {
                ForEach(MediaModel.Tool.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Nằm trên nền navy nên dùng giao diện tối để chữ các tab còn đọc được.
            .environment(\.colorScheme, .dark)
            .disabled(model.isBusy)
        }
        .padding(.horizontal, 20)
        .padding(.top, 15)
        .padding(.bottom, 14)
        .background(Brand.navy)
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 14) {
            switch model.tool {
            case .duplicates:
                Toggle("Tìm cả ảnh giống nhau (đã nén lại, đổi cỡ)", isOn: $model.includeSimilar).toggleStyle(.checkbox)
            case .images:
                Text("Chất lượng \(Int(model.imageOptions.quality * 100))%").monospacedDigit().frame(width: 112, alignment: .leading)
                Slider(value: $model.imageOptions.quality, in: 0.5...0.95, step: 0.05).frame(width: 120)
                Picker("Cạnh dài", selection: $model.imageOptions.maxDimension) {
                    Text("Giữ kích thước").tag(Int?.none)
                    ForEach([4096, 2560, 1920], id: \.self) { Text("Tối đa \($0) px").tag(Int?.some($0)) }
                }
                .frame(width: 210)
                Picker("Định dạng", selection: $model.imageOptions.format) {
                    ForEach(ImageCompressionOptions.Format.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 210)
                Toggle("Ghi đè bản gốc", isOn: $model.imageOptions.replaceOriginal).toggleStyle(.checkbox)
            case .organize:
                Picker("Xếp theo", selection: $model.scheme) {
                    ForEach(OrganizeScheme.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 240)
                Picker("Cách làm", selection: $model.copyInsteadOfMove) {
                    Text("Chuyển file").tag(false)
                    Text("Chép, giữ bản gốc").tag(true)
                }
                .frame(width: 230)
            case .videos:
                Picker("Chất lượng", selection: $model.videoQuality) {
                    ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 330)
                Toggle("Ghi đè bản gốc", isOn: $model.replaceVideos).toggleStyle(.checkbox)
            }
            Spacer()
            if model.tool != .duplicates {
                Toggle("Gồm thư mục con", isOn: $model.recursive).toggleStyle(.checkbox)
            }
        }
        .disabled(model.isBusy)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if model.folder == nil {
            ContentUnavailableView {
                Label("Chọn thư mục ảnh hoặc video", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Thư viện Photos không bị đụng tới. Mọi file xoá đều vào Thùng rác.")
            } actions: {
                Button("Chọn thư mục…") { model.chooseFolder() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isBusy, !hasPartialResults {
            WorkProgressView(progress: model.progress, stopping: model.stopping, cancel: { model.cancel() })
        } else {
            VStack(spacing: 0) {
                if model.isBusy { progressBanner }
                switch model.tool {
                case .duplicates: duplicateList
                case .images, .videos: compressionList
                case .organize: organizeList
                }
            }
        }
    }

    /// Bảng ảnh, video được hiện ngay trong lúc quét; các công cụ khác chờ tới khi xong.
    private var hasPartialResults: Bool {
        (model.tool == .images || model.tool == .videos) && !model.rows.isEmpty && model.results.isEmpty
    }

    private var progressBanner: some View {
        HStack(spacing: 12) {
            ProgressView(value: model.progress.fraction).tint(Brand.teal).frame(width: 160)
            Text(model.progress.phase).fontWeight(.medium).foregroundStyle(Brand.navy)
            Text(model.progress.detail).foregroundStyle(Brand.muted).lineLimit(1).truncationMode(.middle)
            Spacer()
            if model.stopping {
                ProgressView().controlSize(.small)
                Text("Đang dừng…").foregroundStyle(Brand.warning)
            } else {
                Button("Dừng") { model.cancel() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Brand.teal.opacity(0.08))
    }

    @ViewBuilder private var duplicateList: some View {
        if model.duplicates.isEmpty {
            placeholder("Tìm ảnh và video trùng nhau", "Tìm xong không có file nào bị chọn sẵn. Bạn tự chọn bản cần xoá; file đã chọn vào Thùng rác, mỗi nhóm luôn giữ ít nhất một bản.")
        } else {
            VStack(spacing: 0) {
                // Chỉ một chiều cuộn: khung cuộn ngang lồng trong danh sách sẽ nuốt thao tác lăn chuột dọc.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.pageGroups) { group in
                            groupSection(group)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .id(model.groupPage)
                groupPager
            }
        }
    }

    private func groupSection(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.match == .exact ? "Giống hệt nhau" : "Nhìn giống nhau")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(group.match == .exact ? Risk.safe.color : Risk.review.color)
                Text("\(group.files.count) file").font(.caption).foregroundStyle(Brand.muted)
                Spacer()
                Text("Dọn được \(formatBytes(group.reclaimable))").font(.caption).foregroundStyle(Brand.muted)
                if group.files.contains(where: { model.marked.contains($0.id) }) {
                    Button("Bỏ chọn") { model.unmark(group) }.font(.caption)
                }
                Button("Chọn bản thừa") { model.markExtras(in: group) }.font(.caption)
            }
            .buttonStyle(.link)
            // Lưới tự xuống dòng khi nhóm có nhiều file, thay cho cuộn ngang.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 190), alignment: .top)],
                      alignment: .leading, spacing: 14) {
                ForEach(group.files) { file in
                    DuplicateTile(file: file, folder: relative(file.url.deletingLastPathComponent()),
                                  isMarked: model.marked.contains(file.id),
                                  isSuggested: file == group.suggestedKeep,
                                  toggle: { model.toggle(file, in: group) },
                                  preview: { PreviewController.shared.show(file.url, among: group.files.map(\.url)) })
                }
            }
        }
        .padding(.vertical, 12)
    }

    private var groupPager: some View {
        HStack(spacing: 10) {
            Button { model.groupPage = 0 } label: { Image(systemName: "chevron.left.2") }
                .disabled(model.groupPage == 0)
            Button { model.groupPage -= 1 } label: { Image(systemName: "chevron.left") }
                .disabled(model.groupPage == 0)
            Text("Trang \(model.groupPage + 1) / \(model.groupPageCount)").monospacedDigit().foregroundStyle(Brand.navy)
            Button { model.groupPage += 1 } label: { Image(systemName: "chevron.right") }
                .disabled(model.groupPage >= model.groupPageCount - 1)
            Button { model.groupPage = model.groupPageCount - 1 } label: { Image(systemName: "chevron.right.2") }
                .disabled(model.groupPage >= model.groupPageCount - 1)
            Spacer()
            Button("Chọn bản thừa trên trang này") { model.markExtrasOnPage() }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)
            if model.pageHasMarks {
                Button("Bỏ chọn trang này") { model.unmarkPage() }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
            }
            let first = model.groupPage * model.groupsPerPage + 1
            let last = min((model.groupPage + 1) * model.groupsPerPage, model.duplicates.count)
            Text("Nhóm \(first)–\(last) trong \(model.duplicates.count)").foregroundStyle(Brand.muted).monospacedDigit()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var compressionList: some View {
        if !model.results.isEmpty {
            VStack(spacing: 0) {
                HStack {
                    Text("Kết quả nén").font(Brand.heading(14)).foregroundStyle(Brand.navy)
                    Spacer()
                    Button("Quay lại danh sách") { model.listCandidates() }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                List(model.results) { result in
                    HStack {
                        Image(systemName: result.output == nil ? "minus.circle" : "checkmark.circle.fill")
                            .foregroundStyle(result.output == nil ? Brand.muted : Risk.safe.color)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.source.lastPathComponent).foregroundStyle(Brand.navy).lineLimit(1)
                            Text(result.skipped ?? result.output?.path ?? "").font(.caption).foregroundStyle(Brand.muted)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if let output = result.output {
                            Text("\(formatBytes(result.before)) → \(formatBytes(result.after))").monospacedDigit()
                            Button { NSWorkspace.shared.activateFileViewerSelecting([output]) } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Text(formatBytes(result.before)).monospacedDigit().foregroundStyle(Brand.muted)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        } else if model.rows.isEmpty {
            placeholder(model.tool == .videos ? "Video trong thư mục" : "Ảnh trong thư mục",
                        "Liệt kê toàn bộ file kèm nhãn Trùng và Lớn, sau đó chọn file để nén hoặc chuyển vào Thùng rác.")
        } else {
            VStack(spacing: 0) {
                tableBar
                Table(Array(model.pageRows), selection: $model.selection, sortOrder: $model.sortOrder) {
                    TableColumn("") { row in
                        Toggle("", isOn: Binding(
                            get: { model.selection.contains(row.id) },
                            set: { on in
                                if on { model.selection.insert(row.id) } else { model.selection.remove(row.id) }
                            }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                    }
                    .width(24)
                    TableColumn("") { row in
                        Button { preview(row.file.url) } label: { Thumbnail(url: row.file.url) }
                            .buttonStyle(.plain)
                            .help("Xem trước")
                    }
                    .width(44)
                    TableColumn("Tên", value: \.name) { row in
                        Text(row.name).foregroundStyle(Brand.navy).lineLimit(1).help(row.file.url.path)
                    }
                    TableColumn("Thư mục", value: \.folder) { row in
                        Text(relative(row.file.url.deletingLastPathComponent()))
                            .foregroundStyle(Brand.muted).lineLimit(1).truncationMode(.middle)
                            .help(row.file.url.deletingLastPathComponent().path)
                    }
                    TableColumn("Kích thước", value: \.pixels) { row in
                        Text(row.pixels > 0 ? "\(row.width) × \(row.height)" : "—").monospacedDigit().foregroundStyle(Brand.muted)
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("Dung lượng", value: \.size) { row in
                        Text(formatBytes(row.size)).monospacedDigit().foregroundStyle(Brand.navy)
                    }
                    .width(min: 80, ideal: 90)
                    TableColumn("Ghi chú") { row in
                        HStack(spacing: 4) {
                            if row.copies > 1 { badge("Trùng ×\(row.copies)", Brand.warning) }
                            if row.size >= Int64(model.largeMB) * 1_000_000 { badge("Lớn", Risk.review.color) }
                        }
                    }
                    .width(min: 110, ideal: 130)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Xem trước") { preview(ids.first.map { URL(fileURLWithPath: $0) }) }
                    Button("Hiện trong Finder") { reveal(ids) }
                    Button("Nén") {
                        model.selection = ids
                        startCompression()
                    }
                    Button("Chuyển vào Thùng rác") {
                        model.selection = ids
                        confirmTrash()
                    }
                } primaryAction: { ids in
                    preview(ids.first.map { URL(fileURLWithPath: $0) })
                }
                .id(model.page)
                .onKeyPress(.space) {
                    guard let id = model.selection.first else { return .ignored }
                    preview(URL(fileURLWithPath: id))
                    return .handled
                }
                pager
            }
        }
    }

    private var pager: some View {
        HStack(spacing: 10) {
            Button { model.page = 0 } label: { Image(systemName: "chevron.left.2") }
                .disabled(model.page == 0)
                .help("Trang đầu")
            Button { model.page -= 1 } label: { Image(systemName: "chevron.left") }
                .disabled(model.page == 0)
                .help("Trang trước")
            Text("Trang \(model.page + 1) / \(model.pageCount)")
                .monospacedDigit()
                .foregroundStyle(Brand.navy)
            Button { model.page += 1 } label: { Image(systemName: "chevron.right") }
                .disabled(model.page >= model.pageCount - 1)
                .help("Trang sau")
            Button { model.page = model.pageCount - 1 } label: { Image(systemName: "chevron.right.2") }
                .disabled(model.page >= model.pageCount - 1)
                .help("Trang cuối")
            Spacer()
            let first = model.visibleRows.isEmpty ? 0 : model.page * model.pageSize + 1
            let last = min((model.page + 1) * model.pageSize, model.visibleRows.count)
            Text("File \(first)–\(last) trong \(model.visibleRows.count)")
                .foregroundStyle(Brand.muted)
                .monospacedDigit()
            Picker("Mỗi trang", selection: $model.pageSize) {
                ForEach([100, 200, 500, 1000], id: \.self) { Text("\($0) file / trang").tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var tableBar: some View {
        HStack(spacing: 12) {
            Picker("Lọc", selection: $model.rowFilter) {
                ForEach(RowFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            Picker("Từ", selection: $model.largeMB) {
                ForEach([1, 2, 3, 5, 10, 20, 50], id: \.self) { Text("Lớn từ \($0) MB").tag($0) }
            }
            .labelsHidden()
            .frame(width: 140)
            Spacer()
            Button("Chọn bản thừa trong nhóm trùng") { model.selectExtraCopies() }
            Button("Chọn cả trang") { model.selectPage() }
            Button("Chọn tất cả \(model.visibleRows.count) file") { model.selectAllVisible() }
            if !model.selection.isEmpty {
                Button("Bỏ chọn") { model.selection = [] }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Quick Look cho phép dùng phím mũi tên để duyệt các file quanh file đang xem.
    private func preview(_ url: URL?) {
        guard let url else { return }
        PreviewController.shared.show(url, among: model.pageRows.map(\.file.url))
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func reveal(_ ids: Set<String>) {
        NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) })
    }

    private func startCompression() {
        let replacing = model.tool == .videos ? model.replaceVideos : model.imageOptions.replaceOriginal
        let run = model.tool == .videos ? model.compressVideos : model.compressImages
        guard replacing else { return run() }
        confirm("Ghi đè \(model.selection.count) bản gốc?",
                "Bản gốc được chuyển vào Thùng rác khi bản nén nhỏ hơn. Bản nén có mất chi tiết, không khôi phục được từ bản nén.",
                "Nén và ghi đè", run)
    }

    private func confirmTrash() {
        let last = model.selectedLastCopies
        let size = model.selectedRows.reduce(Int64(0)) { $0 + $1.size }
        let warning = last > 0 ? "\(last) file không còn bản nào khác trong thư mục, sẽ mất hẳn nếu đổ Thùng rác." : "Mọi file đã chọn đều còn bản khác."
        confirm("Chuyển \(model.selection.count) file vào Thùng rác?",
                "Dọn được \(formatBytes(size)) sau khi đổ Thùng rác. \(warning)",
                "Chuyển vào Thùng rác", model.trashSelected)
    }

    @ViewBuilder private var organizeList: some View {
        if model.plan.isEmpty {
            placeholder("Xếp ảnh theo ngày chụp",
                        "Ngày lấy từ EXIF, không có thì lấy ngày tạo file. Bấm Xem trước để biết file sẽ đi đâu trước khi làm.")
        } else {
            List(model.plan.prefix(500), id: \.from) { move in
                VStack(alignment: .leading, spacing: 1) {
                    Text(move.from.lastPathComponent).foregroundStyle(Brand.navy).lineLimit(1)
                    Text("→ \(relative(move.to.deletingLastPathComponent()))").font(.caption).foregroundStyle(Brand.muted)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.notice ?? summary).foregroundStyle(Brand.muted).lineLimit(2)
            Spacer()
            actions
        }
        .padding(12)
    }

    private var summary: String {
        switch model.tool {
        case .duplicates:
            guard !model.duplicates.isEmpty else { return "" }
            return model.marked.isEmpty
                ? "\(model.duplicates.count) nhóm trùng. Chưa chọn file nào; tick ô Chọn để xoá ở file cần xoá, bấm ảnh để xem trước."
                : "\(model.duplicates.count) nhóm trùng. Đã chọn \(model.marked.count) file, \(formatBytes(model.markedSize))."
        case .images, .videos:
            guard !model.rows.isEmpty, model.results.isEmpty else { return "" }
            let shown = model.visibleRows.reduce(Int64(0)) { $0 + $1.size }
            let chosen = model.selectedRows.reduce(Int64(0)) { $0 + $1.size }
            return "Đang hiện \(model.visibleRows.count)/\(model.rows.count) file, \(formatBytes(shown))."
                + (model.selection.isEmpty ? " Chọn file để nén hoặc xoá." : " Đã chọn \(model.selection.count) file, \(formatBytes(chosen)).")
        case .organize:
            return model.plan.isEmpty ? "" : "\(model.plan.count) file sẽ được \(model.copyInsteadOfMove ? "chép" : "chuyển")."
        }
    }

    @ViewBuilder private var actions: some View {
        let disabled = model.isBusy || model.folder == nil
        switch model.tool {
        case .duplicates:
            if model.duplicatesPartial {
                primary("Quét tiếp phần còn lại") { model.findDuplicates() }.disabled(disabled)
                    .help("Phần đã quét được lấy lại từ chỉ mục nên rất nhanh; chỉ file chưa quét mới phải đọc.")
            } else {
                Button(model.duplicates.isEmpty ? "Tìm trùng" : "Quét lại") { model.findDuplicates() }.disabled(disabled)
            }
            if !model.duplicates.isEmpty {
                if model.marked.isEmpty {
                    Button("Chọn bản thừa ở mọi nhóm") { model.markExtrasEverywhere() }.disabled(disabled)
                } else {
                    Button("Bỏ chọn tất cả") { model.marked = [] }.disabled(disabled)
                }
            }
            if !model.marked.isEmpty {
                primary("Chuyển \(model.marked.count) file vào Thùng rác") {
                    confirm("Chuyển \(model.marked.count) file vào Thùng rác?",
                            "Dọn được \(formatBytes(model.markedSize)) sau khi đổ Thùng rác. Mỗi nhóm vẫn giữ ít nhất một bản.",
                            "Chuyển vào Thùng rác", model.trashMarked)
                }
                .disabled(disabled)
            }
        case .images, .videos:
            Button(model.rows.isEmpty ? "Liệt kê file" : "Quét lại") { model.listCandidates() }.disabled(disabled)
            if !model.selection.isEmpty, model.results.isEmpty {
                Button("Chuyển \(model.selection.count) file vào Thùng rác") { confirmTrash() }.disabled(disabled)
                primary("Nén \(model.selection.count) file") { startCompression() }.disabled(disabled)
            }
        case .organize:
            if let last = model.lastOrganize, model.plan.isEmpty {
                Button("Hoàn tác \(last.moves.count) file") { model.undoOrganize() }.disabled(disabled)
            }
            Button("Xem trước") { model.makePlan() }.disabled(disabled)
            if !model.plan.isEmpty {
                primary(model.copyInsteadOfMove ? "Chép \(model.plan.count) file" : "Chuyển \(model.plan.count) file") {
                    model.applyPlan()
                }
                .disabled(disabled)
            }
        }
    }

    private func primary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.borderedProminent).tint(Risk.safe.color)
    }

    private func confirm(_ title: String, _ message: String, _ action: String, _ perform: @escaping () -> Void) {
        confirmation = Confirmation(title: title, message: message, action: action, perform: perform)
    }

    private func placeholder(_ title: String, _ text: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "photo.stack")
        } description: {
            VStack(spacing: 6) {
                Text(text)
                if let last = model.lastScan {
                    Text("Đã quét thư mục này lúc \(last.date.formatted(date: .abbreviated, time: .shortened)). Lần quét tới chỉ đọc lại file mới hoặc đã thay đổi nên sẽ nhanh hơn.")
                        .foregroundStyle(Brand.teal)
                } else {
                    Text("Chưa quét thư mục này. Lần đầu với thư mục lớn có thể mất vài phút; có thể bấm Dừng bất cứ lúc nào.")
                }
            }
        } actions: {
            Button(startTitle, action: start)
                .buttonStyle(.borderedProminent)
                .tint(Brand.teal)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var startTitle: String {
        switch model.tool {
        case .duplicates: return "Tìm trùng"
        case .images, .videos: return "Liệt kê file"
        case .organize: return "Xem trước"
        }
    }

    private func start() {
        switch model.tool {
        case .duplicates: model.findDuplicates()
        case .images, .videos: model.listCandidates()
        case .organize: model.makePlan()
        }
    }

    private func relative(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let root = model.folder?.standardizedFileURL.path, path.hasPrefix(root) else { return path }
        return path.count > root.count ? String(path.dropFirst(root.count + 1)) : ""
    }
}

enum RowFilter: String, CaseIterable, Identifiable {
    case all = "Tất cả"
    case large = "Dung lượng lớn"
    case duplicates = "Bị trùng"
    var id: String { rawValue }
}

/// Một dòng trong bảng ảnh hoặc video.
struct MediaRow: Identifiable, Sendable {
    let file: MediaFile
    var width: Int
    var height: Int
    /// Nhóm file giống hệt nhau, nil nếu không trùng với file nào.
    var group: String?
    var copies: Int

    var id: String { file.id }
    var name: String { file.url.lastPathComponent }
    var folder: String { file.url.deletingLastPathComponent().path }
    var size: Int64 { file.size }
    var pixels: Int { width * height }

    /// Đếm lại số bản trong nhóm sau khi có file bị chuyển đi.
    static func recount(_ rows: [MediaRow]) -> [MediaRow] {
        let counts = Dictionary(grouping: rows.compactMap(\.group), by: { $0 }).mapValues(\.count)
        return rows.map { row in
            var row = row
            row.copies = row.group.flatMap { counts[$0] } ?? 1
            return row
        }
    }
}

private struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 4).fill(Brand.surface)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64),
                                                       scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}

private struct WorkProgressView: View {
    let progress: WorkProgress
    let stopping: Bool
    let cancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            HexIcon(symbol: "photo.on.rectangle", color: Brand.teal, size: 54)
            Text(progress.phase).font(Brand.heading(17)).foregroundStyle(Brand.navy)
            ProgressView(value: progress.fraction).tint(Brand.teal).frame(width: 360)
            Text(progress.detail).font(.callout).foregroundStyle(Brand.muted).lineLimit(1).truncationMode(.middle)
                .frame(width: 420, height: 18)
            Text("\(Int(progress.fraction * 100))%").font(Brand.heading(13, "SemiBold")).foregroundStyle(Brand.navy)
            if stopping {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Đang dừng, kết quả sẽ hiện ngay khi xong…").foregroundStyle(Brand.warning)
                }
            } else if let cancel {
                Button("Dừng và xem kết quả đã quét", action: cancel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Một file trong nhóm trùng. Bấm ảnh chỉ để xem trước; muốn xoá phải tick ô riêng.
private struct DuplicateTile: View {
    let file: MediaFile
    /// Thư mục chứa file, tính từ thư mục đã chọn.
    let folder: String
    let isMarked: Bool
    let isSuggested: Bool
    let toggle: () -> Void
    let preview: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: preview) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let thumbnail {
                            Image(nsImage: thumbnail).resizable().scaledToFill()
                        } else {
                            Rectangle().fill(Brand.surface)
                        }
                    }
                    .frame(width: 150, height: 110)
                    .clipped()
                    .opacity(isMarked ? 0.45 : 1)
                    if isMarked {
                        Text("Sẽ xoá")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(.white)
                            .background(Brand.warning, in: Capsule())
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(isMarked ? Brand.warning : Brand.line, lineWidth: isMarked ? 2 : 1))
            }
            .buttonStyle(.plain)
            .help("Xem trước")
            Toggle("Chọn để xoá", isOn: Binding(get: { isMarked }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(isMarked ? Brand.warning : Brand.slate)
            Text(file.url.lastPathComponent).font(.caption).foregroundStyle(Brand.navy).lineLimit(1)
                .frame(width: 150, alignment: .leading).help(file.url.path)
            Label(folder.isEmpty ? "(thư mục gốc)" : folder, systemImage: "folder")
                .font(.caption2)
                .foregroundStyle(Brand.slate)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: 150, alignment: .leading)
                .help(file.url.deletingLastPathComponent().path)
                .textSelection(.enabled)
            Text(formatBytes(file.size) + (isSuggested ? " · bản tốt nhất" : ""))
                .font(.caption2).foregroundStyle(Brand.muted)
            Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                .buttonStyle(.link).font(.caption2)
        }
        .task(id: file.id) {
            let request = QLThumbnailGenerator.Request(fileAt: file.url, size: CGSize(width: 300, height: 220),
                                                       scale: 2, representationTypes: .thumbnail)
            thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}
