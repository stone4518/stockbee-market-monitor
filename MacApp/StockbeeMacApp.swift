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
                .frame(minWidth: 990, minHeight: 640)
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

/// 不带滚动的整页，仅用于 --full 截图
struct FullDashboard: View {
    @EnvironmentObject var model: MonitorModel
    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            HStack(alignment: .top, spacing: 14) {
                LeftPanel().frame(minWidth: 470, maxWidth: .infinity)
                RightPanel().frame(minWidth: 470, maxWidth: .infinity)
            }
            .padding(14)
            StatusBar()
        }
        .background(Palette.background)
        .environment(\.colorScheme, .light)
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
        let view: NSView
        if args.contains("--full") {
            // 完整内容：离屏渲染不带滚动的整页（窗口高度受屏幕限制，无法一次显示全部）
            let host = NSHostingView(rootView: FullDashboard().environmentObject(model))
            host.frame = NSRect(x: 0, y: 0, width: size.width, height: 400)
            host.layoutSubtreeIfNeeded()
            host.frame.size.height = max(400, host.fittingSize.height)
            let off = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: host.frame.width, height: host.frame.height),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            off.contentView = host
            off.orderBack(nil)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            view = host
            size = host.frame.size
        } else {
            guard let win = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first else { exit(2) }
            win.setContentSize(size)
            win.center()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let v = win.contentView else { exit(3) }
            view = v
            size = v.bounds.size
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(3) }
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
