#if os(macOS)
import SwiftUI

@main struct StockbeeMacApp: App {
    @StateObject private var model = MonitorModel()
    var body: some Scene {
        WindowGroup("Stockbee Market Monitor") {
            DashboardView()
                .environmentObject(model)
                .frame(minWidth: 1120, minHeight: 740)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1480, height: 960)
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新最新数据") { Task { await model.refresh() } }.keyboardShortcut("r", modifiers: .command)
                Button("数据源设置") { model.showSettings = true }.keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
#endif
