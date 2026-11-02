import AppKit
import MacCleanCore
import SwiftUI

@MainActor
final class ProcessModel: ObservableObject {
    enum Sort: String, CaseIterable, Identifiable {
        case memory = "RAM"
        case cpu = "CPU"
        var id: String { rawValue }
    }

    @Published var groups: [ProcessGroup] = []
    @Published var usage = SystemUsage()
    @Published var sort = Sort.memory { didSet { resort() } }
    @Published var query = ""
    @Published var showSystem = UserDefaults.standard.bool(forKey: "showSystemProcesses") {
        didSet { UserDefaults.standard.set(showSystem, forKey: "showSystemProcesses") }
    }
    @Published var message: String?
    @Published var loadFailed = false

    private var isLoading = false

    var visibleGroups: [ProcessGroup] {
        ProcessMonitor.visible(groups, includeSystem: showSystem, query: query)
    }

    var hiddenCount: Int { showSystem ? 0 : groups.filter { $0.protection != nil }.count }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task.detached(priority: .utility) { [weak self] in
            let entries = ProcessMonitor.snapshot()
            let groups = entries.map { ProcessMonitor.group($0) }
            let usage = ProcessMonitor.systemUsage(cpuTotal: entries?.reduce(0) { $0 + $1.cpu } ?? 0)
            await MainActor.run {
                guard let self else { return }
                self.isLoading = false
                self.loadFailed = groups == nil
                if let groups {
                    self.groups = groups
                    self.usage = usage
                    self.resort()
                }
            }
        }
    }

    private func resort() {
        groups.sort { sort == .memory ? $0.memory > $1.memory : $0.cpu > $1.cpu }
    }

    /// App được yêu cầu thoát qua macOS để còn hỏi lưu file; tiến trình lẻ nhận tín hiệu.
    func stop(_ group: ProcessGroup, force: Bool) {
        if let path = group.bundlePath, group.protection == nil,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == path }) {
            let sent = force ? app.forceTerminate() : app.terminate()
            message = sent ? "Đã gửi lệnh tắt \(group.name). App có thể hỏi lưu file trước khi thoát."
                           : "\(group.name) không nhận lệnh tắt. Hãy thử Buộc tắt."
        } else {
            let failures = group.processes.compactMap { ProcessMonitor.stop($0, force: force) }
            message = failures.first ?? "Đã gửi lệnh tắt \(group.name)."
        }
        refreshSoon()
    }

    func stop(_ entry: ProcessEntry, force: Bool) {
        message = ProcessMonitor.stop(entry, force: force) ?? "Đã gửi lệnh tắt \(entry.name) (PID \(entry.pid))."
        refreshSoon()
    }

    private func refreshSoon() {
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            refresh()
        }
    }
}

/// Yêu cầu tắt đang chờ người dùng xác nhận.
private struct StopRequest: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let warning: String?
    let force: Bool
    let perform: () -> Void
}

struct ProcessesView: View {
    @StateObject private var model = ProcessModel()
    @State private var pending: StopRequest?

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            Divider()
            content
            Divider()
            footer
        }
        .onAppear { model.refresh() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in model.refresh() }
        .alert(pending.map { "\($0.force ? "Buộc tắt" : "Tắt") \($0.name)?" } ?? "",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { request in
            Button(request.force ? "Buộc tắt" : "Tắt", role: .destructive) { request.perform() }
            Button("Huỷ", role: .cancel) {}
        } message: { request in
            Text(([request.detail, request.warning,
                   request.force ? "Dữ liệu chưa lưu sẽ mất." : "Hãy lưu công việc đang mở trước."] as [String?])
                .compactMap { $0 }.joined(separator: "\n"))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appTitle)
                .font(Brand.heading(14, "SemiBold"))
                .foregroundStyle(.white)
                .lineLimit(1)
            HStack(spacing: 32) {
                gauge("RAM đang dùng", "\(formatBytes(model.usage.memoryUsed)) / \(formatBytes(model.usage.memoryTotal))",
                      value: Double(model.usage.memoryUsed), total: Double(max(1, model.usage.memoryTotal)))
                gauge("CPU", "\(Int(model.usage.cpuPercent))%", value: model.usage.cpuPercent, total: 100)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 15)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.navy)
    }

    private func gauge(_ title: String, _ value: String, value current: Double, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Brand.heading(13, "SemiBold")).foregroundStyle(.white.opacity(0.75))
            Text(value).font(Brand.heading(22)).foregroundStyle(.white).monospacedDigit()
            ProgressView(value: min(current, total), total: total)
                .tint(current / total > 0.9 ? Brand.warning : Brand.teal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Sắp xếp", selection: $model.sort) {
                ForEach(ProcessModel.Sort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            TextField("Tìm tên hoặc PID", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Toggle("Hiện tiến trình hệ thống", isOn: $model.showSystem)
                .toggleStyle(.checkbox)
                .foregroundStyle(Brand.slate)
                .fixedSize()
            Spacer()
            Text("Cập nhật mỗi 3 giây").font(.caption).foregroundStyle(Brand.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if model.loadFailed, model.groups.isEmpty {
            ContentUnavailableView("Không đọc được danh sách tiến trình", systemImage: "exclamationmark.triangle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.visibleGroups) { group in
                GroupRow(group: group, sort: model.sort) { pending = request(for: group, force: $0) } stop: { entry, force in
                    pending = request(for: entry, warning: group.warning, force: force)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var footer: some View {
        HStack {
            Text(model.message ?? summary)
                .foregroundStyle(Brand.muted)
                .lineLimit(1)
            Spacer()
        }
        .padding(12)
    }

    private var summary: String {
        let shown = "\(model.visibleGroups.count) nhóm tiến trình"
        return model.hiddenCount > 0 ? "\(shown), đang ẩn \(model.hiddenCount) nhóm hệ thống." : "\(shown)."
    }

    private func request(for group: ProcessGroup, force: Bool) -> StopRequest {
        StopRequest(name: group.name,
                    detail: "\(group.processes.count) tiến trình, đang dùng \(formatBytes(group.memory)) RAM.",
                    warning: group.warning, force: force) { model.stop(group, force: force) }
    }

    private func request(for entry: ProcessEntry, warning: String?, force: Bool) -> StopRequest {
        StopRequest(name: "\(entry.name) (PID \(entry.pid))", detail: "Đang dùng \(formatBytes(entry.memory)) RAM.",
                    warning: warning, force: force) { model.stop(entry, force: force) }
    }
}

private struct GroupRow: View {
    let group: ProcessGroup
    let sort: ProcessModel.Sort
    let stopGroup: (Bool) -> Void
    let stop: (ProcessEntry, Bool) -> Void
    @State private var expanded = false

    init(group: ProcessGroup, sort: ProcessModel.Sort, stopGroup: @escaping (Bool) -> Void,
         stop: @escaping (ProcessEntry, Bool) -> Void) {
        self.group = group
        self.sort = sort
        self.stopGroup = stopGroup
        self.stop = stop
    }

    private var icon: NSImage? {
        group.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "terminal").foregroundStyle(Brand.muted)
                    }
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name).fontWeight(.semibold).foregroundStyle(Brand.navy).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(Brand.muted).lineLimit(1)
                }
                Spacer()
                metric(String(format: "%.1f%%", group.cpu), emphasized: sort == .cpu).frame(width: 64, alignment: .trailing)
                metric(formatBytes(group.memory), emphasized: sort == .memory).frame(width: 84, alignment: .trailing)
                StopMenu(locked: group.protection != nil, stop: stopGroup).frame(width: 74)
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Xem từng tiến trình")
            }
            if expanded {
                ForEach(group.processes.sorted { $0.memory > $1.memory }.prefix(40)) { entry in
                    HStack(spacing: 8) {
                        Text("\(entry.pid)").font(.caption.monospacedDigit()).foregroundStyle(Brand.muted)
                            .frame(width: 56, alignment: .leading)
                        Text(entry.command).font(.caption.monospaced()).foregroundStyle(Brand.slate)
                            .lineLimit(1).truncationMode(.middle).help(entry.command)
                        Spacer()
                        Text(String(format: "%.1f%%", entry.cpu)).font(.caption.monospacedDigit())
                        Text(formatBytes(entry.memory)).font(.caption.monospacedDigit())
                            .frame(width: 70, alignment: .trailing)
                        StopMenu(locked: group.protection != nil) { stop(entry, $0) }.controlSize(.small).frame(width: 70)
                    }
                    .padding(.leading, 34)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        let count = "\(group.processes.count) tiến trình"
        if let protection = group.protection { return "\(count) · \(protection)" }
        return group.warning.map { "\(count) · \($0)" } ?? count
    }

    private func metric(_ text: String, emphasized: Bool) -> some View {
        Text(text)
            .monospacedDigit()
            .fontWeight(emphasized ? .semibold : .regular)
            .foregroundStyle(emphasized ? Brand.navy : Brand.muted)
    }
}

private struct StopMenu: View {
    let locked: Bool
    let stop: (Bool) -> Void

    var body: some View {
        if locked {
            Image(systemName: "lock.fill").foregroundStyle(Brand.line).help("Không được tắt")
        } else {
            Menu("Tắt") {
                Button("Tắt") { stop(false) }
                Button("Buộc tắt", role: .destructive) { stop(true) }
            } primaryAction: {
                stop(false)
            }
        }
    }
}
