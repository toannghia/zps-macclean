import AppKit
import MacCleanCore
import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--scan") {
            printScan()
        } else {
            ZPSMacCleanApp.main()
        }
    }

    /// Quét chỉ đọc và in kết quả, không xoá gì.
    private static func printScan() {
        let roots = CommandLine.arguments.drop { $0 != "--scan" }.dropFirst().map { URL(fileURLWithPath: $0) }
        guard let items = try? JunkScanner(env: .live).scan(options: ScanOptions(projectRoots: Array(roots))) else {
            print("Không kiểm tra được file đang mở nên chưa quét.")
            return
        }
        for item in items {
            let lock = item.isBlocked ? " [khoá: \(item.blockedBy.joined(separator: ", "))]" : ""
            let kept = item.skippedInUse > 0 ? " [giữ \(item.skippedInUse) đang mở]" : ""
            print("\(formatBytes(item.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(item.risk.label.padding(toLength: 11, withPad: " ", startingAt: 0)) \(item.title)\(lock)\(kept)")
        }
        print("Tổng: \(formatBytes(items.reduce(0) { $0 + $1.size })) trong \(items.count) mục")
    }
}

struct ZPSMacCleanApp: App {
    @StateObject private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup(appTitle) {
            ContentView().environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
