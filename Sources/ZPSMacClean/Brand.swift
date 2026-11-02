import AppKit
import MacCleanCore
import SwiftUI

let appTitle = "ZPS MacClean - Công cụ dọn rác hệ thống thông minh"

/// Nhận diện ZPS: bảng màu chuẩn, Montserrat cho tiêu đề, khối lục giác.
enum Brand {
    static let navy = Color(hex: 0x0D2340)
    static let teal = Color(hex: 0x14B8C5)
    static let green = Color(hex: 0x5DB333)
    static let slate = Color(hex: 0x334155)
    static let muted = Color(hex: 0x64748B)
    static let line = Color(hex: 0xCBD5E1)
    static let surface = Color(hex: 0xF8FAFC)
    /// Cảnh báo chức năng, không thuộc bảng màu thương hiệu.
    static let warning = Color(hex: 0xB45309)

    static func heading(_ size: CGFloat, _ weight: String = "Bold") -> Font {
        .custom("Montserrat-\(weight)", size: size)
    }

    static var logo: NSImage? {
        Bundle.main.url(forResource: "logo", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension Risk {
    var color: Color {
        switch self {
        case .safe: return Color(hex: 0x3F8A1F)
        case .review: return Color(hex: 0x0E7C86)
        }
    }
}

/// Lục giác đỉnh nhọn bo góc như trong logo ZPS.
struct Hexagon: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let points = [
            CGPoint(x: width / 2, y: 0),
            CGPoint(x: width, y: height * 0.25),
            CGPoint(x: width, y: height * 0.75),
            CGPoint(x: width / 2, y: height),
            CGPoint(x: 0, y: height * 0.75),
            CGPoint(x: 0, y: height * 0.25),
        ].map { CGPoint(x: $0.x + rect.minX, y: $0.y + rect.minY) }
        let radius = min(width, height) * 0.14
        var path = Path()
        path.move(to: CGPoint(x: (points[5].x + points[0].x) / 2, y: (points[5].y + points[0].y) / 2))
        for index in points.indices {
            path.addArc(tangent1End: points[index], tangent2End: points[(index + 1) % points.count], radius: radius)
        }
        path.closeSubpath()
        return path
    }
}

struct HexIcon: View {
    let symbol: String
    var color = Brand.navy
    var size: CGFloat = 26

    var body: some View {
        Hexagon()
            .fill(color)
            .frame(width: size * 0.92, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

extension CleanCategory {
    var color: Color {
        switch self {
        case .ai, .docker, .packages: return Brand.teal
        case .projects, .browsers: return Brand.green
        default: return Brand.navy
        }
    }
}
