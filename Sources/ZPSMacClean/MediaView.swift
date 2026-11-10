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
        }
    }
    @Published var recursive = true
    @Published var isBusy = false
    @Published var progress = WorkProgress()
    @Published var notice: String?

    @Published var includeSimilar = true
    @Published var duplicates: [DuplicateGroup] = []
    /// Các file người dùng đã đánh dấu để chuyển vào Thùng rác.
    @Published var marked = Set<String>()

    @Published var imageOptions = ImageCompressionOptions()
    @Published var videoQuality = VideoQuality.hevc1080
    @Published var replaceVideos = false
    @Published var candidates: [MediaFile] = []
    @Published var results: [CompressionResult] = []

    @Published var scheme = OrganizeScheme.yearMonth
    @Published var copyInsteadOfMove = false
    @Published var plan: [OrganizeMove] = []
    @Published var lastOrganize: (moves: [OrganizeMove], copied: Bool)?

    private let video = VideoCompressor()
    private var cancelRequested = false

    init() {
        if let path = UserDefaults.standard.string(forKey: "mediaFolder"),
           FileManager.default.fileExists(atPath: path) {
            folder = URL(fileURLWithPath: path)
        }
    }

    var markedSize: Int64 {
        duplicates.flatMap(\.files).filter { marked.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func reset() {
        duplicates = []
        marked = []
        candidates = []
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
        guard !isBusy, folder != nil else { return }
        isBusy = true
        cancelRequested = false
        notice = nil
        progress = WorkProgress(phase: phase)
        Task.detached(priority: .userInitiated) { [self] in
            await work(self)
            await MainActor.run { self.isBusy = false }
        }
    }

    nonisolated private func report(_ fraction: Double, _ phase: String, _ detail: String = "") {
        Task { @MainActor in
            self.progress = WorkProgress(fraction: fraction, phase: phase, detail: detail)
        }
    }

    private func listFiles(_ kind: MediaKind?) -> [MediaFile] {
        guard let folder else { return [] }
        let all = MediaScanner.files(in: folder, recursive: recursive) { count in
            Task { @MainActor in self.progress = WorkProgress(fraction: 0.02, phase: "Đang tìm file", detail: "\(count) file") }
        }
        return kind.map { kind in all.filter { $0.kind == kind } } ?? all
    }

    // MARK: Ảnh trùng

    func findDuplicates() {
        let similar = includeSimilar
        run("Đang tìm ảnh trùng") { model in
            let files = await model.listFiles(nil)
            let groups = DuplicateFinder.find(files, includeSimilar: similar) { fraction, name in
                model.report(fraction, "Đang so sánh \(files.count) file", name)
            }
            await MainActor.run {
                model.duplicates = groups
                model.marked = Set(groups.flatMap { group in group.files.filter { $0 != group.suggestedKeep }.map(\.id) })
                model.notice = groups.isEmpty ? "Không tìm thấy ảnh hoặc video trùng." : nil
            }
        }
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
            for (index, file) in files.enumerated() {
                model.report(Double(index) / Double(max(1, files.count)), "Đang chuyển vào Thùng rác", file.url.lastPathComponent)
                do { try MediaFiles.trash(file.url) } catch {
                    failures.append("\(file.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            let size = files.reduce(Int64(0)) { $0 + $1.size }
            await MainActor.run {
                model.notice = failures.isEmpty
                    ? "Đã chuyển \(files.count) file (\(formatBytes(size))) vào Thùng rác. Đổ Thùng rác để giải phóng dung lượng."
                    : "Còn \(failures.count) file chưa chuyển được: \(failures.first ?? "")"
                model.duplicates = []
                model.marked = []
            }
        }
    }

    // MARK: Nén ảnh và video

    func listCandidates() {
        let kind: MediaKind = tool == .videos ? .video : .image
        run("Đang tìm file") { model in
            let files = await model.listFiles(kind).sorted { $0.size > $1.size }
            await MainActor.run {
                model.candidates = files
                model.results = []
                model.notice = files.isEmpty ? "Không có file phù hợp trong thư mục này." : nil
            }
        }
    }

    func compressImages() {
        guard let folder else { return }
        let files = candidates
        let options = imageOptions
        run("Đang nén ảnh") { model in
            var results: [CompressionResult] = []
            for (index, file) in files.enumerated() {
                if await model.cancelRequested { break }
                model.report(Double(index) / Double(max(1, files.count)), "Đang nén ảnh (\(index + 1)/\(files.count))",
                             file.url.lastPathComponent)
                results.append(ImageCompressor.compress(file, options: options, root: folder))
            }
            await model.finishCompression(results)
        }
    }

    func compressVideos() {
        guard let folder else { return }
        let files = candidates
        let quality = videoQuality
        let replace = replaceVideos
        let compressor = video
        run("Đang nén video") { model in
            var results: [CompressionResult] = []
            for (index, file) in files.enumerated() {
                if await model.cancelRequested { break }
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
        cancelRequested = true
        video.cancel()
    }

    private func finishCompression(_ results: [CompressionResult]) {
        self.results = results
        let saved = results.reduce(Int64(0)) { $0 + $1.saved }
        let done = results.filter { $0.output != nil }.count
        notice = "Đã nén \(done)/\(results.count) file, tiết kiệm \(formatBytes(saved))."
            + (cancelRequested ? " Đã dừng theo yêu cầu." : "")
    }

    // MARK: Sắp xếp

    func makePlan() {
        guard let folder else { return }
        let scheme = scheme
        run("Đang đọc ngày chụp") { model in
            let files = await model.listFiles(nil)
            model.report(0.5, "Đang đọc ngày chụp", "\(files.count) file")
            let plan = PhotoOrganizer.plan(files, root: folder, scheme: scheme)
            await MainActor.run {
                model.plan = plan
                model.notice = plan.isEmpty ? "Ảnh đã được xếp đúng chỗ." : nil
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appTitle).font(Brand.heading(14, "SemiBold")).foregroundStyle(.white).lineLimit(1)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ảnh & Video").font(Brand.heading(13, "SemiBold")).foregroundStyle(.white.opacity(0.75))
                    Text(model.folder?.lastPathComponent ?? "Chưa chọn thư mục")
                        .font(Brand.heading(24)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
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
        } else if model.isBusy {
            WorkProgressView(progress: model.progress, cancel: cancelAction)
        } else {
            switch model.tool {
            case .duplicates: duplicateList
            case .images, .videos: compressionList
            case .organize: organizeList
            }
        }
    }

    private var cancelAction: (() -> Void)? {
        guard model.tool == .images || model.tool == .videos else { return nil }
        return { model.cancel() }
    }

    @ViewBuilder private var duplicateList: some View {
        if model.duplicates.isEmpty {
            placeholder("Tìm ảnh và video trùng nhau", "Bản đẹp nhất của mỗi nhóm được giữ lại, các bản khác vào Thùng rác.")
        } else {
            List(model.duplicates) { group in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(group.match == .exact ? "Giống hệt nhau" : "Nhìn giống nhau")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(group.match == .exact ? Risk.safe.color : Risk.review.color)
                        Text("\(group.files.count) file").font(.caption).foregroundStyle(Brand.muted)
                        Spacer()
                        Text("Dọn được \(formatBytes(group.reclaimable))").font(.caption).foregroundStyle(Brand.muted)
                    }
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(group.files) { file in
                                DuplicateTile(file: file, isKept: !model.marked.contains(file.id),
                                              isSuggested: file == group.suggestedKeep) { model.toggle(file, in: group) }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var compressionList: some View {
        if !model.results.isEmpty {
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
                    if result.output != nil {
                        Text("\(formatBytes(result.before)) → \(formatBytes(result.after))").monospacedDigit()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([result.output!]) } label: {
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
        } else if model.candidates.isEmpty {
            placeholder(model.tool == .videos ? "Nén video bằng HEVC" : "Nén ảnh JPEG, HEIC",
                        "Kết quả lưu vào thư mục \"\(MediaScanner.outputFolderName)\" trong thư mục đã chọn, bản gốc giữ nguyên trừ khi bạn chọn ghi đè.")
        } else {
            List(model.candidates.prefix(500)) { file in
                HStack {
                    Text(file.url.lastPathComponent).foregroundStyle(Brand.navy).lineLimit(1)
                    Spacer()
                    Text(formatBytes(file.size)).monospacedDigit().foregroundStyle(Brand.muted)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
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
            return model.duplicates.isEmpty ? "" : "\(model.duplicates.count) nhóm trùng. Bấm vào ảnh để đổi bản giữ lại."
        case .images, .videos:
            let total = model.candidates.reduce(Int64(0)) { $0 + $1.size }
            return model.candidates.isEmpty ? "" : "\(model.candidates.count) file, tổng \(formatBytes(total))."
        case .organize:
            return model.plan.isEmpty ? "" : "\(model.plan.count) file sẽ được \(model.copyInsteadOfMove ? "chép" : "chuyển")."
        }
    }

    @ViewBuilder private var actions: some View {
        let disabled = model.isBusy || model.folder == nil
        switch model.tool {
        case .duplicates:
            Button("Tìm trùng") { model.findDuplicates() }.disabled(disabled)
            if !model.marked.isEmpty {
                primary("Chuyển \(model.marked.count) file vào Thùng rác") {
                    confirm("Chuyển \(model.marked.count) file vào Thùng rác?",
                            "Dọn được \(formatBytes(model.markedSize)) sau khi đổ Thùng rác. Mỗi nhóm vẫn giữ ít nhất một bản.",
                            "Chuyển vào Thùng rác", model.trashMarked)
                }
                .disabled(disabled)
            }
        case .images, .videos:
            Button("Liệt kê file") { model.listCandidates() }.disabled(disabled)
            if !model.candidates.isEmpty, model.results.isEmpty {
                let replacing = model.tool == .videos ? model.replaceVideos : model.imageOptions.replaceOriginal
                primary("Nén \(model.candidates.count) file") {
                    let run = model.tool == .videos ? model.compressVideos : model.compressImages
                    if replacing {
                        confirm("Ghi đè \(model.candidates.count) bản gốc?",
                                "Bản gốc được chuyển vào Thùng rác khi bản nén nhỏ hơn. Ảnh nén có mất chi tiết, không khôi phục được từ bản nén.",
                                "Nén và ghi đè", run)
                    } else {
                        run()
                    }
                }
                .disabled(disabled)
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
        ContentUnavailableView(title, systemImage: "photo.stack", description: Text(text))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func relative(_ url: URL) -> String {
        guard let root = model.folder?.path, url.path.hasPrefix(root) else { return url.path }
        return String(url.path.dropFirst(root.count + 1))
    }
}

private struct WorkProgressView: View {
    let progress: WorkProgress
    let cancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            HexIcon(symbol: "photo.on.rectangle", color: Brand.teal, size: 54)
            Text(progress.phase).font(Brand.heading(17)).foregroundStyle(Brand.navy)
            ProgressView(value: progress.fraction).tint(Brand.teal).frame(width: 360)
            Text(progress.detail).font(.callout).foregroundStyle(Brand.muted).lineLimit(1).truncationMode(.middle)
                .frame(width: 420, height: 18)
            Text("\(Int(progress.fraction * 100))%").font(Brand.heading(13, "SemiBold")).foregroundStyle(Brand.navy)
            if let cancel { Button("Dừng sau file hiện tại", action: cancel) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DuplicateTile: View {
    let file: MediaFile
    let isKept: Bool
    let isSuggested: Bool
    let toggle: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
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
                    .opacity(isKept ? 1 : 0.45)
                    Text(isKept ? "Giữ" : "Xoá")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(isKept ? Risk.safe.color : Brand.warning, in: Capsule())
                        .padding(6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(isKept ? Risk.safe.color : Brand.line, lineWidth: 2))
            }
            .buttonStyle(.plain)
            Text(file.url.lastPathComponent).font(.caption).foregroundStyle(Brand.navy).lineLimit(1).frame(width: 150, alignment: .leading)
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
