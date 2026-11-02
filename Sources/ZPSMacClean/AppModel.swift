import AppKit
import Foundation
import MacCleanCore

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [CleanItem] = []
    @Published var selected = Set<String>()
    @Published var isBusy = false
    @Published var progress = WorkProgress()
    @Published var report: CleanReport?
    @Published var scanError: String?
    @Published var disks: [DiskInfo] = []
    @Published var retentionDays: Int {
        didSet { UserDefaults.standard.set(retentionDays, forKey: "retentionDays") }
    }
    @Published var projectRoots: [URL] {
        didSet { UserDefaults.standard.set(projectRoots.map(\.path), forKey: "projectRoots") }
    }

    private let env = CleanEnvironment.live
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ZPS-MacClean/clean.log")

    init() {
        let defaults = UserDefaults.standard
        let days = defaults.integer(forKey: "retentionDays")
        retentionDays = days > 0 ? days : 30
        if let saved = defaults.stringArray(forKey: "projectRoots") {
            projectRoots = saved.map { URL(fileURLWithPath: $0) }
        } else {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            projectRoots = ["Projects", "Developer", "Code", "Sites"]
                .map { home.appendingPathComponent($0) }
                .filter { fm.fileExists(atPath: $0.path) }
        }
    }

    var selectedItems: [CleanItem] { items.filter { selected.contains($0.id) && !$0.isBlocked } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var totalFound: Int64 { items.reduce(0) { $0 + $1.size } }

    func items(in category: CleanCategory?) -> [CleanItem] {
        guard let category else { return items }
        return items.filter { $0.category == category }
    }

    func size(of category: CleanCategory) -> Int64 {
        items(in: category).reduce(0) { $0 + $1.size }
    }

    func scan() {
        guard !isBusy else { return }
        isBusy = true
        progress = WorkProgress(phase: "Bắt đầu quét")
        refreshDisk()
        let env = env
        let options = ScanOptions(retentionDays: retentionDays, projectRoots: projectRoots)
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = try? JunkScanner(env: env).scan(options: options) { update in
                Task { @MainActor in self?.apply(update) }
            }
            await MainActor.run {
                guard let self else { return }
                self.scanError = result == nil ? "Không kiểm tra được file đang mở nên chưa quét. Hãy thử quét lại." : nil
                let found = result ?? []
                self.items = found
                self.selected = Set(found.filter { $0.risk == .safe && !$0.isBlocked }.map(\.id))
                self.isBusy = false
            }
        }
    }

    func clean() {
        let targets = selectedItems
        guard !isBusy, !targets.isEmpty else { return }
        isBusy = true
        progress = WorkProgress(phase: "Chuẩn bị dọn")
        let cleaner = Cleaner(env: env, projectRoots: projectRoots, logURL: logURL)
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = cleaner.clean(targets) { update in
                Task { @MainActor in self?.apply(update) }
            }
            await MainActor.run {
                guard let self else { return }
                self.isBusy = false
                self.report = result
                self.scan()
            }
        }
    }

    /// Các luồng báo về không theo thứ tự nên thanh tiến trình chỉ được đi lên.
    private func apply(_ update: WorkProgress) {
        guard isBusy else { return }
        var next = update
        next.fraction = max(progress.fraction, update.fraction)
        next.foundBytes = max(progress.foundBytes, update.foundBytes)
        progress = next
    }

    func refreshDisk() {
        disks = Cleaner.disks(home: FileManager.default.homeDirectoryForCurrentUser, projectRoots: projectRoots)
    }

    func addProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            projectRoots += panel.urls.filter { !projectRoots.contains($0) }
        }
    }

    func openLog() {
        NSWorkspace.shared.open(logURL)
    }
}

func formatBytes(_ bytes: Int64) -> String {
    bytes == 0 ? "0 GB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
