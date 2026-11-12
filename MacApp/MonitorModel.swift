#if os(macOS)
import SwiftUI
import AppKit
import Foundation

/// 本地只读缓存：最近一次成功抓取的广度与行情。只用于断网时查看，永远不参与完整评分。
struct CachedState: Codable {
    var snapshot: BreadthSnapshot
    var quotes: [String: QuoteHistory]
    var vendor: String?
    var savedAt: Date
}

@MainActor final class MonitorModel: ObservableObject {
    @Published var snapshot: BreadthSnapshot?
    @Published var quotes: [String: QuoteHistory] = [:]
    @Published var quoteVendor: String?
    @Published var quoteRawLatest: [String: String] = [:]
    @Published var sourceMode: String = UserDefaults.standard.string(forKey: "sourceMode") ?? "official"
    @Published var manualSheetURL: String = UserDefaults.standard.string(forKey: "officialSheetURL") ?? ""
    @Published var loading = false
    @Published var lastCheck: Date?
    @Published var lastSuccess: Date?
    @Published var error: String?
    @Published var warnings: [String] = []
    @Published var showSettings = false
    @Published var isCache = false
    @Published var cacheSavedAt: Date?
    @Published var publishNote: String?
    @Published var freshness: Freshness?

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private(set) var started = false
    static let interval: TimeInterval = 15 * 60

    var blockers: [String] {
        var b: [String] = []
        if isCache { b.append("当前显示的是离线缓存（只读），不发布完整评分") }
        if let f = freshness, !f.usableForScoring { b.append("广度数据\(f.label)") }
        if let s = snapshot, !s.official { b.append("数据源不是经官网自动发现的 Stockbee 官方表格") }
        return b
    }
    var assessment: Assessment { Scorer.assess(snapshot, quotes, blockers: blockers) }
    var latestDate: String { snapshot?.latest?.date ?? "—" }
    var status: String {
        if loading { return "正在联网检查…" }
        if let error { return (isCache ? "联网失败，显示缓存：" : "联网失败：") + error }
        if snapshot == nil { return "尚未获取数据" }
        return publishNote ?? "已更新"
    }

    // MARK: 生命周期：只启动一次；15 分钟轮询 + 唤醒后立即检查

    func start() {
        guard !started else { return }
        started = true
        if let c = Self.loadCache() { apply(cache: c) }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 等待网络恢复
                await self?.refresh()
            }
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(sourceMode, forKey: "sourceMode")
        UserDefaults.standard.set(manualSheetURL, forKey: "officialSheetURL")
        showSettings = false
        Task { await refresh() }
    }

    // MARK: 刷新

    func refresh() async {
        if loading { return }   // 防止重复请求
        loading = true
        defer { loading = false; lastCheck = Date() }
        do {
            let data: BreadthSnapshot
            if sourceMode == "thirdparty" { data = try await DataFetcher.fetchThirdParty() }
            else {
                let known = UserDefaults.standard.stringArray(forKey: "discoveredSheetLinks") ?? []
                data = try await DataFetcher.fetchOfficial(manualSheet: manualSheetURL, knownLinks: known)
                if let found = data.discoveredLinks, !found.isEmpty { UserDefaults.standard.set(found, forKey: "discoveredSheetLinks") }
            }
            guard let day = data.latest else { throw MonitorError.missingData("数据源没有有效交易日") }
            let fresh = Freshness.evaluate(dataDate: day.date)
            if fresh == .future { throw MonitorError.invalidData("数据源最新日期 \(day.date) 晚于最近收盘交易日，已拒绝") }

            var notes: [String] = data.ratioConsistency()
            if let n = data.note { notes.insert(n, at: 0) }
            if !TradingCalendar.isTradingDay(day.date) { notes.append("最新日期 \(day.date) 不是 NYSE 交易日，请核对") }
            if !data.official { notes.append("当前为非官方/未核验数据源：\(data.sourceName)") }

            let bundle = await DataFetcher.fetchQuotes()
            var aligned: [String: QuoteHistory] = [:]
            var rawLatest: [String: String] = [:]
            for (s, h) in bundle.quotes {
                rawLatest[s] = h.lastDate
                let t = h.through(day.date)
                if t.lastDate == day.date { aligned[s] = t }
                else { notes.append("\(s)：\(h.vendor) 尚无 \(day.date) 收盘（最新 \(h.lastDate ?? "无")），该项不评分") }
            }
            if bundle.quotes.count < DataFetcher.etfSymbols.count {
                notes.append(contentsOf: bundle.failures.prefix(6))
            }

            let previous = isCache ? nil : snapshot?.latest?.date
            let cachedDate = Self.loadCache()?.snapshot.latest?.date
            let before = previous ?? cachedDate
            if data.revisionNotice != nil { publishNote = "官方数据正在修订（已采用实时版 \(day.date)）" }
            else if let before, before == day.date { publishNote = "已检查：Stockbee 尚无新交易日，最新仍为 \(day.date)" }
            else if let before { publishNote = "发现新交易日 \(day.date)（上次 \(before)）" }
            else { publishNote = "已读取最新已发布交易日 \(day.date)" }

            snapshot = data
            quotes = aligned
            quoteVendor = bundle.vendor?.rawValue
            quoteRawLatest = rawLatest
            freshness = fresh
            warnings = notes
            isCache = false
            error = nil
            lastSuccess = Date()
            Self.saveCache(CachedState(snapshot: data, quotes: aligned, vendor: bundle.vendor?.rawValue, savedAt: Date()))
        } catch {
            self.error = error.localizedDescription
            if let c = Self.loadCache() { apply(cache: c) }
            else { snapshot = nil; quotes = [:]; quoteVendor = nil; freshness = nil; warnings = [] }
        }
    }

    private func apply(cache c: CachedState) {
        snapshot = c.snapshot
        quotes = c.quotes
        quoteVendor = c.vendor
        isCache = true
        cacheSavedAt = c.savedAt
        freshness = c.snapshot.latest.map { Freshness.evaluate(dataDate: $0.date) }
        warnings = ["离线缓存保存于 \(c.savedAt.formatted(date: .abbreviated, time: .shortened))，仅供查看"]
    }

    // MARK: 缓存（~/Library/Application Support/StockbeeMarketMonitor）

    static var cacheDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("StockbeeMarketMonitor", isDirectory: true)
    }
    static func saveCache(_ c: CachedState) {
        guard ProcessInfo.processInfo.environment["STOCKBEE_NO_CACHE"] != "1" else { return }
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(c)
            try data.write(to: cacheDir.appendingPathComponent("latest.json"), options: .atomic)
            if let d = c.snapshot.latest?.date {   // 按交易日归档，只读历史
                let archive = cacheDir.appendingPathComponent("breadth-\(d).json")
                if !FileManager.default.fileExists(atPath: archive.path) { try data.write(to: archive) }
            }
        } catch { }
    }
    static func loadCache() -> CachedState? {
        guard ProcessInfo.processInfo.environment["STOCKBEE_NO_CACHE"] != "1",
              let data = try? Data(contentsOf: cacheDir.appendingPathComponent("latest.json")) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(CachedState.self, from: data)
    }
}
#endif
