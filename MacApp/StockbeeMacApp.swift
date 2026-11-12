#if os(macOS)
import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct StockbeeMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = MonitorModel()
    var body: some Scene {
        Window("Stockbee Market Monitor", id: "main") {
            DashboardView()
                .environmentObject(model)
                .frame(minWidth: 1120, minHeight: 720)
                .task { await SnapshotRunner.runIfRequested(model) }
        }
        .defaultSize(width: 1480, height: 980)
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新最新数据") { Task { await model.refresh() } }.keyboardShortcut("r", modifiers: .command)
                Button("数据源设置…") { model.showSettings = true }.keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// 自动化验收用：`StockbeeMac --snapshot out.png [--size 1480x1000]`
/// 等首次联网刷新结束后，把窗口内容渲染为 PNG，并写出同名 .txt 状态摘要，然后退出。
@MainActor enum SnapshotRunner {
    static func runIfRequested(_ model: MonitorModel) async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        var size = CGSize(width: 1480, height: 1000)
        if let j = args.firstIndex(of: "--size"), j + 1 < args.count {
            let p = args[j + 1].split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { size = CGSize(width: p[0], height: p[1]) }
        }
        for _ in 0..<240 {
            if model.lastCheck != nil && !model.loading { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let win = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first else { exit(2) }
        win.setContentSize(size)
        win.center()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard let view = win.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(3) }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
        let a = model.assessment
        let summary = [
            "窗口 \(Int(size.width))x\(Int(size.height))",
            "状态：\(model.status)",
            "数据日：\(model.latestDate) · 时效：\(model.freshness?.label ?? "—") · 缓存：\(model.isCache)",
            "行情商：\(model.quoteVendor ?? "无")",
            "分项：" + a.items.map { "\($0.name)=\($0.score.map { String($0) } ?? "N/A")" }.joined(separator: "；"),
            "总分：\(a.total.map { String($0) } ?? "待评估") · 等级：\(a.grade ?? "待评估") · VCP：\(a.vcp) · HTF：\(a.htf)",
            "阻断：" + a.blockers.joined(separator: "；"),
            "提示：" + model.warnings.joined(separator: "；")
        ].joined(separator: "\n")
        try? summary.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
        exit(0)
    }
}
#endif
