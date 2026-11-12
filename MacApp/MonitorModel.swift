#if os(macOS)
import SwiftUI
import Foundation

@MainActor final class MonitorModel: ObservableObject {
    @Published var snapshot: BreadthSnapshot?
    @Published var quotes: [String: QuoteHistory] = [:]
    @Published var quoteSources: [String:String] = [:]
    @Published var sourceMode: String = UserDefaults.standard.string(forKey: "sourceMode") ?? "official"
    @Published var manualSheetURL: String = UserDefaults.standard.string(forKey: "officialSheetURL") ?? ""
    @Published var loading = false
    @Published var lastCheck: Date?
    @Published var error: String?
    @Published var warnings: [String] = []
    @Published var showSettings = false
    var assessment: Assessment { Scorer.assess(snapshot, quotes) }
    var latestDate: String { snapshot?.latest?.date ?? "—" }
    var status: String {
        if loading { return "正在更新…" }
        if let error { return "拉取失败：" + error }
        if snapshot == nil { return "等待获取正式数据" }
        return "已读取数据源最近一条收盘数据（不代表当天已更新）"
    }
    func saveSettings() {
        UserDefaults.standard.set(sourceMode, forKey: "sourceMode")
        UserDefaults.standard.set(manualSheetURL, forKey: "officialSheetURL")
        showSettings = false
        Task { await refresh() }
    }
    func refresh() async {
        if loading { return }
        loading = true
        error = nil
        warnings = []
        defer { loading = false; lastCheck = Date() }
        do {
            let data: BreadthSnapshot
            if sourceMode == "thirdparty" { data = try await DataFetcher.fetchThirdParty() }
            else { data = try await DataFetcher.fetchOfficial(manualSheet: manualSheetURL) }
            guard let day = data.latest else { throw MonitorError.missingData("数据源没有有效交易日") }
            guard day.date <= DayClock.nyDate(Date()) else { throw MonitorError.invalidData("数据源包含未来交易日，已停止评分") }
            snapshot = data
            warnings.append(contentsOf: data.ratioConsistency())
            if !data.official { warnings.append("当前不是经官网自动发现的官方数据：可能为第三方复算或用户自填表格，请核对其真实性和股票池") }
            let iso = ISO8601DateFormatter()
            if let dayDate = iso.date(from: day.date + "T22:00:00Z"), Date().timeIntervalSince(dayDate) > 4 * 86400 {
                warnings.append("已发布数据超过4个自然日，请确认是否仍在更新")
            }
            var collected: [String: QuoteHistory] = [:]
            var sources: [String: String] = [:]
            var failures: [String] = []
            await withTaskGroup(of: (String,QuoteHistory?,String?,String?).self) { group in
                for symbol in ["SPY","QQQ","XLK","SMH","XLY"] {
                    group.addTask {
                        do {
                            let (history, origin) = try await DataFetcher.fetchQuote(symbol)
                            return (symbol, history.through(day.date), origin, nil)
                        } catch { return (symbol, nil, nil, error.localizedDescription) }
                    }
                }
                for await (symbol,history,source,issue) in group {
                    if let history, history.lastDate == day.date {
                        collected[symbol] = history
                        sources[symbol] = source ?? ""
                    } else {
                        failures.append(symbol + "：" + (issue ?? "最新行情日与Stockbee交易日不一致"))
                    }
                }
            }
            // Relative strength comparisons must use the same price-data vendor.
            if let benchmarkSource = sources["SPY"] {
                for sector in ["XLK","SMH","XLY"] where sources[sector] != nil && sources[sector] != benchmarkSource {
                    collected.removeValue(forKey: sector)
                    failures.append(sector + "：与SPY行情提供商不同，为避免错误相对强度已禁用")
                }
            }
            quotes = collected
            quoteSources = sources
            warnings.append(contentsOf: failures)
            if data.rows.count < 10 { warnings.append("官方数据不足10个交易日：10D Ratio无法独立核验，完整评分暂不可用") }
        } catch {
            // Clear previous data to prevent stale or accidentally mixed-session scores.
            snapshot = nil
            quotes = [:]
            quoteSources = [:]
            self.error = error.localizedDescription
        }
    }
}
#endif
