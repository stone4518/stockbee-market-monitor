import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 网络层：只负责“取数 + 解析 + 标注来源”，不做评分。
public enum DataFetcher {
    public static let etfSymbols = ["SPY", "QQQ", "XLK", "SMH", "XLY"]
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// 调试/测试用：设置环境变量 STOCKBEE_FORCE_OFFLINE=1 时所有请求立即失败，用于验证断网处理。
    static var forcedOffline: Bool { ProcessInfo.processInfo.environment["STOCKBEE_FORCE_OFFLINE"] == "1" }

    public static func get(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> String {
        try await getFinal(url, headers: headers, timeout: timeout).0
    }
    /// 同 get，另返回跟随重定向后的最终 URL。
    public static func getFinal(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> (String, URL) {
        guard url.scheme == "https" else { throw MonitorError.unsupportedSource("仅允许 HTTPS 数据源") }
        if forcedOffline { throw MonitorError.missingData("网络不可用（STOCKBEE_FORCE_OFFLINE 测试模式）") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,text/csv,application/json;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw MonitorError.missingData("网络请求失败（\(url.host ?? "?")）：\(error.localizedDescription)") }
        guard let r = resp as? HTTPURLResponse else { throw MonitorError.invalidData("无效响应：\(url.host ?? "?")") }
        switch r.statusCode {
        case 200: break
        case 429: throw MonitorError.invalidData("\(url.host ?? "?") 限流（HTTP 429）")
        case 401, 403: throw MonitorError.invalidData("\(url.host ?? "?") 拒绝访问（HTTP \(r.statusCode)）")
        default: throw MonitorError.invalidData("\(url.host ?? "?") 返回 HTTP \(r.statusCode)")
        }
        guard data.count < 10_000_000, let str = String(data: data, encoding: .utf8) else { throw MonitorError.invalidData("数据过大或编码不可解析") }
        guard !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MonitorError.missingData("\(url.host ?? "?") 返回空内容") }
        return (str, r.url ?? url)
    }

    // MARK: Stockbee 官方

    /// - Parameter knownLinks: 以前从官网页面成功发现过的表格地址（App 会持久化），官网页面暂不可达时使用。
    public static func fetchOfficial(manualSheet: String? = nil, knownLinks: [String] = []) async throws -> BreadthSnapshot {
        let manual = (manualSheet ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var links: [String] = []
        var discovered: [String]? = nil
        var note: String? = nil
        if !manual.isEmpty { links = [manual] }
        else {
            var pageError: Error? = nil
            for attempt in 0..<2 {
                do {
                    let html = try await get(URL(string: GoogleSheetDiscovery.officialPage)!)
                    links = GoogleSheetDiscovery.sheetLinks(html: html)
                    discovered = links
                    pageError = nil
                    break
                } catch {
                    pageError = error
                    if attempt == 0 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
                }
            }
            if let pageError {
                if !knownLinks.isEmpty {
                    links = knownLinks
                    note = "官网 MM 页面暂不可达（\(pageError.localizedDescription)），改用此前从官网发现的表格地址"
                } else {
                    links = [GoogleSheetDiscovery.lastVerifiedEmbed]
                    note = "官网 MM 页面暂不可达（\(pageError.localizedDescription)），改用 \(GoogleSheetDiscovery.lastVerifiedDate) 核实的官网嵌入表格地址"
                }
            }
        }
        guard !links.isEmpty else { throw MonitorError.missingData("官网页面未解析到 Google Sheets 嵌入地址（页面结构可能已变化）。可在设置中粘贴官方表格链接。") }
        let name = manual.isEmpty ? "Stockbee 官网嵌入的 Google Sheet" : "用户提供的 Google Sheet（官方关联未核验）"
        var details: [String] = []
        for link in links {
            // 两个渠道并行：发布版（Publish to web 的 CSV，有缓存）与实时版（gviz 直接读表格当前内容）。
            async let publishedTask = fetchPublished(link)
            async let liveTask = fetchLive(link)
            let published = await publishedTask
            let live = await liveTask
            var notes: [String] = note.map { [$0] } ?? []
            let chosen: (rows: [BreadthDay], url: String)
            let channel: String
            var revision: String? = nil
            switch (live, published) {
            case (.success(let l), .success(var p)):
                // 验收用：STOCKBEE_SIMULATE_REVISION=1 时把发布版最新一行改成 2026-11-12 实际遇到的旧数值，用于截图验证提示
                if ProcessInfo.processInfo.environment["STOCKBEE_SIMULATE_REVISION"] == "1", !p.rows.isEmpty {
                    p.rows[0].up4 -= 7; p.rows[0].down4 -= 2; p.rows[0].quarterUp -= 1; p.rows[0].quarterDown -= 4
                }
                chosen = l; channel = "实时版（与发布版交叉核对）"
                let diffs = ChannelCompare.differences(live: l.rows, published: p.rows)
                if !diffs.isEmpty { revision = "官方数据正在修订：实时版与发布版不一致（已采用实时版）。" + diffs.joined(separator: "；") }
            case (.success(let l), .failure(let e)):
                chosen = l; channel = "实时版（发布版不可用）"; notes.append("发布版渠道不可用：\(e.localizedDescription)")
            case (.failure(let e), .success(let p)):
                chosen = p; channel = "发布版（实时渠道不可用）"; notes.append("实时渠道不可用，改用发布版（可能有缓存延迟）：\(e.localizedDescription)")
            case (.failure(let le), .failure(let pe)):
                details.append("实时：\(le.localizedDescription)"); details.append("发布版：\(pe.localizedDescription)")
                continue
            }
            return BreadthSnapshot(sourceName: name, sourceURL: chosen.url, official: manual.isEmpty, rows: chosen.rows,
                                   discoveredLinks: discovered, note: notes.isEmpty ? nil : notes.joined(separator: "；"),
                                   channel: channel, revisionNotice: revision)
        }
        let first = details.first ?? "未知错误"
        throw MonitorError.missingData(note == nil ? "官方数据读取失败：\(first)" : "官网页面与官方表格均无法访问：\(first)")
    }

    static func parseBreadth(_ contents: String) throws -> [BreadthDay] {
        let tables: [[[String]]] = (contents.lowercased().contains("<html") || contents.contains("<table"))
            ? TabularParser.htmlTables(contents) : [TabularParser.csv(contents)]
        var best: [BreadthDay] = []
        for t in tables { if let rows = try? TabularParser.breadth(t), (rows.first?.date ?? "") > (best.first?.date ?? "") || rows.count > best.count && rows.first?.date == best.first?.date { best = rows } }
        guard !best.isEmpty else { throw MonitorError.invalidData("未找到含日期/4% Up/Down/Quarter Up/Down 列的表") }
        return best
    }
    /// 发布版：Publish to web 输出的 CSV（官网 iframe 所用渠道，Google 会缓存）。
    static func fetchPublished(_ link: String) async -> Result<(rows: [BreadthDay], url: String), Error> {
        var last: Error = MonitorError.missingData("无可用的发布版地址")
        for url in GoogleSheetDiscovery.csvURLs(link) where !url.absoluteString.contains("/gviz/") {
            do { return .success((try parseBreadth(try await get(url)), url.absoluteString)) } catch { last = error }
        }
        return .failure(last)
    }
    /// 实时版：gviz 查询接口直接读取表格当前内容（不经过“发布到网络”的缓存）。
    static func fetchLive(_ link: String) async -> Result<(rows: [BreadthDay], url: String), Error> {
        do {
            var id = GoogleSheetDiscovery.documentID(link)
            if id == nil {   // 旧版 key 地址：跟随重定向得到新版文档 ID
                let (body, final) = try await getFinal(URL(string: link)!)
                id = GoogleSheetDiscovery.documentID(final.absoluteString) ?? GoogleSheetDiscovery.documentID(inText: body)
            }
            guard let id else { throw MonitorError.missingData("无法确定表格文档 ID，实时渠道不可用") }
            let url = URL(string: "https://docs.google.com/spreadsheets/d/\(id)/gviz/tq?tqx=out:csv")!
            return .success((try parseBreadth(try await get(url)), url.absoluteString))
        } catch { return .failure(error) }
    }

    /// 可选的非官方独立复算源。永远标注为非官方，不会自动替代官方数据。
    public static func fetchThirdParty() async throws -> BreadthSnapshot {
        let url = URL(string: "https://us.stage2stocks.com/market-timing/market-monitor")!
        let html = try await get(url)
        for table in TabularParser.htmlTables(html) {
            if let days = try? TabularParser.breadth(table) {
                return BreadthSnapshot(sourceName: "Stage2Stocks 独立复算（非官方，股票池不同）", sourceURL: url.absoluteString, official: false, rows: days)
            }
        }
        throw MonitorError.invalidData("第三方页面结构改变，未找到完整数据表")
    }

    // MARK: ETF 日线（多行情商，同一次评分只使用同一家）

    public enum QuoteVendor: String, CaseIterable, Codable {
        case yahoo = "Yahoo Finance 日线"
        case nasdaq = "Nasdaq.com 历史行情"
        case cboe = "Cboe 延时行情"
    }

    public static func fetch(_ symbol: String, from vendor: QuoteVendor) async throws -> QuoteHistory {
        guard etfSymbols.contains(symbol) else { throw MonitorError.unsupportedSource("不支持的代码 \(symbol)") }
        let text: String
        switch vendor {
        case .yahoo:
            do { text = try await get(URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?range=1y&interval=1d")!) }
            catch { text = try await get(URL(string: "https://query2.finance.yahoo.com/v8/finance/chart/\(symbol)?range=1y&interval=1d")!) }
        case .nasdaq:
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "America/New_York"); f.dateFormat = "yyyy-MM-dd"
            let to = f.string(from: Date()), from = f.string(from: Date().addingTimeInterval(-400 * 86400))
            text = try await get(URL(string: "https://api.nasdaq.com/api/quote/\(symbol)/historical?assetclass=etf&fromdate=\(from)&todate=\(to)&limit=400")!,
                                 headers: ["Accept": "application/json, text/plain, */*", "Origin": "https://www.nasdaq.com", "Referer": "https://www.nasdaq.com/"])
        case .cboe:
            text = try await get(URL(string: "https://cdn.cboe.com/api/global/delayed_quotes/charts/historical/\(symbol).json")!)
        }
        var h = try QuoteParser.parse(text, vendor: vendor, symbol: symbol)
        h.vendor = vendor.rawValue
        try QuoteParser.validate(h)
        return h
    }

    public struct QuoteBundle {
        public var quotes: [String: QuoteHistory]
        public var vendor: QuoteVendor?
        public var failures: [String]
    }

    /// 依次尝试各行情商，返回第一家 5 只 ETF 全部成功的结果；都不完整时返回成功只数最多的一家。
    public static func fetchQuotes(order: [QuoteVendor] = QuoteVendor.allCases) async -> QuoteBundle {
        var best = QuoteBundle(quotes: [:], vendor: nil, failures: [])
        var allFailures: [String] = []
        for vendor in order {
            var got: [String: QuoteHistory] = [:]
            var fails: [String] = []
            await withTaskGroup(of: (String, Result<QuoteHistory, Error>).self) { group in
                for s in etfSymbols {
                    group.addTask {
                        do { return (s, .success(try await fetch(s, from: vendor))) } catch { return (s, .failure(error)) }
                    }
                }
                for await (s, r) in group {
                    switch r {
                    case .success(let h): got[s] = h
                    case .failure(let e): fails.append("\(vendor.rawValue) \(s)：\(e.localizedDescription)")
                    }
                }
            }
            allFailures += fails
            if got.count == etfSymbols.count { return QuoteBundle(quotes: got, vendor: vendor, failures: allFailures) }
            if got.count > best.quotes.count { best = QuoteBundle(quotes: got, vendor: vendor, failures: []) }
        }
        best.failures = allFailures
        return best
    }
}

public enum QuoteParser {
    static func num(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String {
            let c = s.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
            return Double(c)
        }
        return nil
    }
    static func finish(_ symbol: String, _ map: [String: Double]) throws -> QuoteHistory {
        // 只保留最近 260 个交易日（约一年），评分最多用到 55 个；更早的历史（如 Cboe 自 2004 年起含少量脏数据）不参与。
        let dates = Array(map.keys.sorted().suffix(260))
        guard dates.count >= 60 else { throw MonitorError.invalidData("\(symbol) 历史行情不足60个交易日（\(dates.count)）") }
        return QuoteHistory(symbol: symbol, dates: dates, closes: dates.compactMap { map[$0] })
    }
    public static func parse(_ text: String, vendor: DataFetcher.QuoteVendor, symbol: String) throws -> QuoteHistory {
        guard let data = text.data(using: .utf8), let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MonitorError.invalidData("\(vendor.rawValue) \(symbol)：不是有效 JSON（可能被拦截或要求浏览器验证）")
        }
        var map: [String: Double] = [:]
        switch vendor {
        case .yahoo:
            guard let chart = raw["chart"] as? [String: Any], let result = (chart["result"] as? [[String: Any]])?.first,
                  let ts = result["timestamp"] as? [Any],
                  let quote = ((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first,
                  let closes = quote["close"] as? [Any] else { throw MonitorError.invalidData("Yahoo \(symbol)：缺少日期或收盘价") }
            for (i, t) in ts.enumerated() where i < closes.count {
                guard let sec = num(t), let c = num(closes[i]), c > 0, c.isFinite else { continue }
                map[DayClock.nyDate(Date(timeIntervalSince1970: sec))] = c
            }
        case .nasdaq:
            guard let d = raw["data"] as? [String: Any], let table = d["tradesTable"] as? [String: Any],
                  let rows = table["rows"] as? [[String: Any]] else { throw MonitorError.invalidData("Nasdaq \(symbol)：缺少 tradesTable") }
            for r in rows {
                guard let ds = r["date"] as? String, let day = DayClock.parse(ds), let c = num(r["close"]), c > 0 else { continue }
                map[day] = c
            }
        case .cboe:
            guard let rows = raw["data"] as? [[String: Any]] else { throw MonitorError.invalidData("Cboe \(symbol)：缺少 data") }
            for r in rows {
                guard let ds = r["date"] as? String, let day = DayClock.parse(String(ds.prefix(10))), let c = num(r["close"]), c > 0 else { continue }
                map[day] = c
            }
        }
        return try finish(symbol, map)
    }
    /// 防御：日期必须是交易日；单日涨跌超过 25% 视为未复权拆股或脏数据，拒绝使用。
    public static func validate(_ h: QuoteHistory) throws {
        if let bad = h.dates.first(where: { !TradingCalendar.isTradingDay($0) }) {
            throw MonitorError.invalidData("\(h.symbol) 行情含非交易日 \(bad)")
        }
        for i in 1..<h.closes.count where abs(h.closes[i] / h.closes[i - 1] - 1) > 0.25 {
            throw MonitorError.invalidData("\(h.symbol) 在 \(h.dates[i]) 单日变动超过25%，疑似未复权或数据错误")
        }
    }
}
