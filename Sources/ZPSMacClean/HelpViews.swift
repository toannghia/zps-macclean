import MacCleanCore
import SwiftUI

struct GuideDetail: View {
    let guide: ItemGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            line("Đây là gì", guide.what, Brand.navy)
            line("Nếu xoá", guide.ifDeleted, Brand.navy)
            line("Lấy lại bằng cách", guide.restore, Brand.navy)
            line("Lời khuyên", guide.advice, Risk.safe.color)
        }
    }

    private func line(_ title: String, _ text: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(text).font(.callout).foregroundStyle(Brand.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Bảng giải thích mở từ nút dấu hỏi ở mỗi dòng.
struct ItemHelpPopover: View {
    let item: CleanItem

    private var guides: [ItemGuide] {
        if item.category == .projects {
            return item.action.urls.compactMap { Guides.artifactGuide(named: $0.lastPathComponent) }
        }
        return Guides.guide(forItem: item.id).map { [$0] } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(item.title).font(Brand.heading(15)).foregroundStyle(Brand.navy)
                if item.category == .projects {
                    Text("Chỉ xoá thư mục sinh ra khi cài đặt hoặc build. Mã nguồn và .git được giữ nguyên.")
                        .font(.callout).foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(guides, id: \.name) { guide in
                    VStack(alignment: .leading, spacing: 6) {
                        if guides.count > 1 || item.category == .projects {
                            Text(guide.name).font(.callout.monospaced().weight(.semibold)).foregroundStyle(Brand.navy)
                        }
                        GuideDetail(guide: guide)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 380)
        .frame(maxHeight: 460)
        .background(.white)
    }
}

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var sections: [GuideSection] {
        guard !query.isEmpty else { return Guides.sections }
        return Guides.sections.compactMap { section in
            let matches = section.guides.filter {
                "\($0.name) \($0.what)".localizedCaseInsensitiveContains(query)
            }
            return matches.isEmpty ? nil : GuideSection(title: section.title, guides: matches)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Hướng dẫn").font(Brand.heading(20)).foregroundStyle(Brand.navy)
                Spacer()
                TextField("Tìm mục", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button("Xong") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if query.isEmpty { intro }
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title).font(Brand.heading(15)).foregroundStyle(Brand.navy)
                            if section.title == "Rác trong dự án" {
                                Text("Là các thư mục sinh ra khi cài đặt hoặc build, tạo lại được từ mã nguồn. App chỉ nhận khi có file nhận diện đi kèm, ví dụ node_modules cạnh package.json, và chỉ ở dự án không thay đổi trong số ngày đã đặt.")
                                    .font(.callout).foregroundStyle(Brand.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(section.guides, id: \.name) { guide in
                                DisclosureGroup {
                                    GuideDetail(guide: guide)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 6)
                                } label: {
                                    Text(guide.name).fontWeight(.medium).foregroundStyle(Brand.navy)
                                }
                                Divider()
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 640, height: 620)
        .background(.white)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hai mức trong app").font(Brand.heading(15)).foregroundStyle(Brand.navy)
                level(.safe, "Cache thuần, tự sinh lại, chỉ làm lần mở sau chậm hơn. Được tick sẵn.")
                level(.review, "Lấy lại được nhưng tốn thời gian tải hoặc build. Bạn đọc hướng dẫn rồi tự tick.")
            }
            bullets("App bảo vệ việc đang làm thế nào", Guides.protections)
            bullets("Không bao giờ bị xoá", Guides.neverTouched)
        }
    }

    private func level(_ risk: Risk, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RiskBadge(risk: risk).frame(width: 66, alignment: .leading)
            Text(text).font(.callout).foregroundStyle(Brand.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullets(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Brand.heading(15)).foregroundStyle(Brand.navy)
            ForEach(lines, id: \.self) { line in
                Label {
                    Text(line).font(.callout).foregroundStyle(Brand.slate)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Brand.green)
                }
            }
        }
    }
}
