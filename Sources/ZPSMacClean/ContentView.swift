import AppKit
import MacCleanCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var category: CleanCategory?
    @State private var showConfirm = false
    @State private var showSettings = false
    @State private var showHelp = false
    @State private var showProcesses = false
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 270)
        } detail: {
            VStack(spacing: 0) {
                if showProcesses {
                    ProcessesView()
                } else {
                    header
                    itemList
                    Divider()
                    footer
                }
            }
            .background(.white)
            .ignoresSafeArea(edges: .top)
            .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .tint(Brand.teal)
        .preferredColorScheme(.light)
        .frame(minWidth: 940, minHeight: 600)
        .onAppear { model.scan() }
        // Docker và APFS trả dung lượng chậm hơn lúc xoá nên phải đo lại liên tục.
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in model.refreshDisk() }
        .sheet(isPresented: $showSettings) { SettingsSheet().environmentObject(model) }
        .sheet(isPresented: $showHelp) { HelpSheet() }
        .sheet(item: Binding(get: { model.report.map(ReportBox.init) }, set: { if $0 == nil { model.report = nil } })) {
            ReportSheet(report: $0.report).environmentObject(model)
        }
        .confirmationDialog(confirmTitle, isPresented: $showConfirm, titleVisibility: .visible) {
            Button("Dọn dẹp", role: .destructive) { model.clean() }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private func open(_ item: CleanCategory?) {
        category = item
        showProcesses = false
    }

    private var confirmTitle: String {
        "Dọn \(model.selectedItems.count) mục, khoảng \(formatBytes(model.selectedSize))?"
    }

    private var confirmMessage: String {
        let items = model.selectedItems
        var lines = ["Chỉ xoá cache và file tái tạo được. Lịch sử chat, phiên làm việc và dữ liệu vừa dùng được giữ nguyên."]
        if items.contains(where: { if case .command = $0.action { return true } else { return false } }) {
            lines.append("Lệnh Docker không hoàn tác được.")
        }
        return lines.joined(separator: "\n")
    }

    private var sidebar: some View {
        List {
            Section {
                ForEach(model.disks) { DiskGauge(disk: $0) }
            }
            Section {
                SidebarRow(title: "Tiến trình", symbol: "cpu", color: Brand.green, size: 0,
                           isSelected: showProcesses) { showProcesses = true }
                SidebarRow(title: "Tất cả", symbol: "square.grid.2x2", color: Brand.navy,
                           size: model.totalFound, isSelected: !showProcesses && category == nil) { open(nil) }
                ForEach(CleanCategory.allCases) { item in
                    SidebarRow(title: item.title, symbol: item.symbol, color: item.color,
                               size: model.size(of: item), isSelected: !showProcesses && category == item) { open(item) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            Group {
                if let logo = Brand.logo {
                    Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
                } else {
                    Text("ZERO POINT SYSTEMS").font(Brand.heading(13)).foregroundStyle(Brand.navy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text("From Zero To Possibilities.")
                Text("Build Smart. Scale Fast.")
            }
            .font(Brand.heading(10, "SemiBold"))
            .foregroundStyle(Brand.teal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(Brand.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appTitle)
                .font(Brand.heading(14, "SemiBold"))
                .foregroundStyle(.white)
                .lineLimit(1)
                // Chừa chỗ cho ba nút cửa sổ khi ẩn sidebar.
                .padding(.leading, columns == .detailOnly ? 76 : 0)
            headerSummary
        }
        .padding(.horizontal, 20)
        .padding(.top, 15)
        .padding(.bottom, 14)
        .background(Brand.navy)
    }

    private var headerSummary: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(category?.title ?? "Tất cả dữ liệu dọn được") · ước tính")
                    .font(Brand.heading(13, "SemiBold"))
                    .foregroundStyle(.white.opacity(0.75))
                Text(formatBytes(model.isBusy && model.items.isEmpty ? model.progress.foundBytes
                                 : category.map(model.size(of:)) ?? model.totalFound))
                    .font(Brand.heading(28))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            Spacer()
            HStack(spacing: 14) {
                headerButton("Hướng dẫn", "questionmark.circle") { showHelp = true }
                headerButton("Cài đặt", "gearshape") { showSettings = true }
                headerButton("Quét lại", "arrow.clockwise") { model.scan() }
                    .disabled(model.isBusy)
                    .opacity(model.isBusy ? 0.4 : 1)
            }
        }
    }

    private func headerButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 17))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    @ViewBuilder private var itemList: some View {
        let items = model.items(in: category)
        if model.isBusy, items.isEmpty {
            ScanProgressView(progress: model.progress)
        } else if items.isEmpty {
            ContentUnavailableView {
                Label(model.scanError == nil ? "Không có gì để dọn" : "Chưa quét được",
                      systemImage: model.scanError == nil ? "checkmark.circle" : "exclamationmark.triangle")
            } description: {
                Text(model.scanError ?? "Mục này đã sạch.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(items) { ItemRow(item: $0) }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.isBusy {
                ProgressView(value: model.progress.fraction)
                    .tint(Brand.teal)
                    .frame(width: 140)
                Text(model.progress.detail.isEmpty ? model.progress.phase : model.progress.detail)
                    .foregroundStyle(Brand.muted).lineLimit(1).truncationMode(.middle)
            } else {
                Text("Đã chọn \(model.selectedItems.count) mục")
                    .foregroundStyle(Brand.muted)
            }
            Spacer()
            Text(formatBytes(model.selectedSize))
                .font(Brand.heading(18))
                .foregroundStyle(Brand.navy)
                .monospacedDigit()
            Button("Dọn dẹp") { showConfirm = true }
                .buttonStyle(.borderedProminent)
                .tint(Risk.safe.color)
                .controlSize(.large)
                .disabled(model.isBusy || model.selectedItems.isEmpty)
        }
        .padding(12)
    }
}

private struct ScanProgressView: View {
    let progress: WorkProgress

    var body: some View {
        VStack(spacing: 14) {
            HexIcon(symbol: "magnifyingglass", color: Brand.teal, size: 54)
            Text(progress.phase).font(Brand.heading(17)).foregroundStyle(Brand.navy)
            ProgressView(value: progress.fraction)
                .tint(Brand.teal)
                .frame(width: 360)
            Text(progress.detail)
                .font(.callout)
                .foregroundStyle(Brand.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 420, height: 18)
            HStack(spacing: 18) {
                Text("\(Int(progress.fraction * 100))%")
                Text("Đã tìm thấy \(formatBytes(progress.foundBytes))")
            }
            .font(Brand.heading(13, "SemiBold"))
            .foregroundStyle(Brand.navy)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReportBox: Identifiable {
    let id = UUID()
    let report: CleanReport
}

private struct DiskGauge: View {
    let disk: DiskInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(disk.name).font(.caption).foregroundStyle(Brand.muted)
            Text("\(formatBytes(disk.free)) trống")
                .font(Brand.heading(17)).foregroundStyle(Brand.navy)
            if disk.total > 0 {
                ProgressView(value: Double(disk.total - disk.free), total: Double(disk.total))
                    .tint(Double(disk.free) / Double(disk.total) < 0.1 ? Brand.warning : Brand.green)
                Text("trên tổng \(formatBytes(disk.total))")
                    .font(.caption).foregroundStyle(Brand.muted)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let color: Color
    let size: Int64
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HexIcon(symbol: symbol, color: color, size: 22)
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(Brand.navy)
                Spacer()
                if size > 0 {
                    Text(formatBytes(size)).font(.caption.monospacedDigit()).foregroundStyle(Brand.muted)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Brand.teal.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
    }
}

private struct ItemRow: View {
    @EnvironmentObject var model: AppModel
    let item: CleanItem
    @State private var expanded = false
    @State private var showHelp = false

    private var isOn: Binding<Bool> {
        Binding(
            get: { model.selected.contains(item.id) && !item.isBlocked },
            set: { on in
                if on { model.selected.insert(item.id) } else { model.selected.remove(item.id) }
            }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(item.isBlocked)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).fontWeight(.semibold).foregroundStyle(Brand.navy).lineLimit(1)
                    RiskBadge(risk: item.risk)
                }
                Text(item.note).font(.callout).foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if item.isBlocked {
                    Label("Đóng \(item.blockedBy.joined(separator: ", ")) rồi quét lại để dọn mục này",
                          systemImage: "lock.fill")
                        .font(.callout).foregroundStyle(Brand.warning)
                }
                if item.skippedInUse > 0 {
                    Text("Giữ lại \(item.skippedInUse) mục đang dùng hoặc vừa dùng.")
                        .font(.callout).foregroundStyle(Brand.muted)
                }
                if expanded { paths }
            }
            Spacer()
            Text(formatBytes(item.size)).monospacedDigit().fontWeight(.semibold).foregroundStyle(Brand.navy)
            Button { showHelp.toggle() } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Giải thích mục này")
            .popover(isPresented: $showHelp, arrowEdge: .trailing) { ItemHelpPopover(item: item) }
            if !item.action.urls.isEmpty {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Xem đường dẫn")
            }
        }
        .padding(.vertical, 4)
    }

    private var paths: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(item.action.urls.prefix(30), id: \.self) { url in
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Text(url.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.link)
            }
            if item.action.urls.count > 30 {
                Text("và \(item.action.urls.count - 30) mục khác").font(.caption).foregroundStyle(Brand.muted)
            }
        }
        .padding(.top, 2)
    }
}

struct RiskBadge: View {
    let risk: Risk

    var body: some View {
        Text(risk.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(risk.color)
            .background(risk.color.opacity(0.12), in: Capsule())
    }
}

private struct ReportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let report: CleanReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Đã dọn \(report.cleanedCount) mục").font(Brand.heading(20)).foregroundStyle(Brand.navy)
            LabeledContent("Dung lượng trống tăng thêm (đo thực)", value: formatBytes(report.actualFreedBytes))
            ForEach(report.freedByDisk) { disk in
                LabeledContent(disk.name, value: formatBytes(disk.free)).foregroundStyle(Brand.muted)
            }
            LabeledContent("Ước tính khi quét", value: formatBytes(report.estimatedBytes))
            Text("Docker trả lại dung lượng dần dần nên số trống ở thanh bên còn tăng thêm sau khi dọn.")
                .font(.callout).foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !report.failures.isEmpty {
                Text("\(report.failures.count) mục chưa dọn").fontWeight(.medium).foregroundStyle(Brand.warning)
                ScrollView {
                    Text(report.failures.joined(separator: "\n"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
            HStack {
                Button("Xem nhật ký") { model.openLog() }
                Spacer()
                Button("Xong") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

private struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cài đặt").font(Brand.heading(20)).foregroundStyle(Brand.navy)
            Stepper("Bỏ qua dự án có thay đổi trong \(model.retentionDays) ngày", value: $model.retentionDays, in: 1...365, step: 7)
            Divider()
            Text("Thư mục dự án cần quét").fontWeight(.medium)
            ForEach(model.projectRoots, id: \.self) { root in
                HStack {
                    Text(root.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button {
                        model.projectRoots.removeAll { $0 == root }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Thêm thư mục…") { model.addProjectRoot() }
                Spacer()
                Button("Xong") {
                    dismiss()
                    model.scan()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
