import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DataFetcher {
    public static func get(_ url: URL) async throws -> String {
        guard url.scheme == "https" else { throw MonitorError.unsupportedSource("仅允许 HTTPS 数据源") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 13_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,text/csv,application/json;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let r = resp as? HTTPURLResponse, r.statusCode == 200 else { throw MonitorError.invalidData("HTTP 请求未成功：\(url.host ?? "未知主机")") }
        guard data.count < 10_000_000, let str = String(data: data, encoding: .utf8) else { throw MonitorError.invalidData("数据过大或编码不可解析") }
        return str
    }
    public static func fetchOfficial(manualSheet: String? = nil) async throws -> BreadthSnapshot {
        var links: [String] = []
        let manuallySupplied = !(manualSheet ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let manualSheet, !manualSheet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { links = [manualSheet] }
        else {
            let html = try await get(URL(string: GoogleSheetDiscovery.officialPage)!)
            links = GoogleSheetDiscovery.sheetLinks(html: html)
        }
        guard !links.isEmpty else { throw MonitorError.missingData("官网页面未解析到Google Sheets嵌入地址。可在设置中粘贴官方表格链接。") }
        var details: [String] = []
        for link in links {
            for url in GoogleSheetDiscovery.csvURLs(link) {
                do {
                    let contents = try await get(url)
                    let arrays: [[[String]]]
                    if contents.lowercased().contains("<html") || contents.contains("<table") {
                        arrays = TabularParser.htmlTables(contents)
                    } else { arrays = [TabularParser.csv(contents)] }
                    for table in arrays {
                        if let rows = try? TabularParser.breadth(table) {
                            return BreadthSnapshot(sourceName: manuallySupplied ? "用户提供的Google Sheet（官方关联未核验）" : "Stockbee官网嵌入的Google Sheet", sourceURL: url.absoluteString, official: !manuallySupplied, rows: rows)
                        }
                    }
                    details.append("\(url.host ?? "?")：无可识别的完整指标表")
                } catch { details.append(error.localizedDescription) }
            }
        }
        throw MonitorError.missingData("官方数据读取失败：" + details.prefix(3).joined(separator: "；"))
    }
    /// Optional non-official independently computed market breadth. Never silently substitute for official data.
    public static func fetchThirdParty() async throws -> BreadthSnapshot {
        let url = URL(string: "https://us.stage2stocks.com/market-timing/market-monitor")!
        let html = try await get(url)
        for table in TabularParser.htmlTables(html) {
            if let days = try? TabularParser.breadth(table) {
                return BreadthSnapshot(sourceName: "Stage2Stocks独立复算（非官方，股票池不同）", sourceURL: url.absoluteString, official: false, rows: days)
            }
        }
        throw MonitorError.invalidData("第三方页面结构改变，未找到完整数据表")
    }

    public static func fetchYahoo(_ symbol: String) async throws -> QuoteHistory {
        guard ["SPY","QQQ","XLK","SMH","XLY"].contains(symbol) else { throw MonitorError.unsupportedSource("不支持的ticker") }
        let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?range=6mo&interval=1d")!
        let jsonText = try await get(url)
        guard let data = jsonText.data(using: .utf8), let raw = try JSONSerialization.jsonObject(with: data) as? [String:Any],
              let chart = raw["chart"] as? [String:Any],
              let results = chart["result"] as? [[String:Any]], let result = results.first,
              let timestamps = result["timestamp"] as? [Double],
              let indicators = result["indicators"] as? [String:Any],
              let quotes = indicators["quote"] as? [[String:Any]], let quote = quotes.first,
              let closes = quote["close"] as? [Any] else {
            throw MonitorError.invalidData("Yahoo价格数据缺少日期或收盘价：\(symbol)")
        }
        var price: [String:Double] = [:]
        for (n, ts) in timestamps.enumerated() {
            guard n < closes.count, let close = closes[n] as? Double, close > 0, close.isFinite else { continue }
            price[DayClock.nyDate(Date(timeIntervalSince1970: ts))] = close
        }
        return QuoteHistory(symbol: symbol, dates: price.keys.sorted(), closes: price.keys.sorted().compactMap { price[$0] })
    }
    public static func fetchStooq(_ symbol: String) async throws -> QuoteHistory {
        guard ["SPY","QQQ","XLK","SMH","XLY"].contains(symbol) else { throw MonitorError.unsupportedSource("不支持的ticker") }
        let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT:0); f.dateFormat = "yyyyMMdd"
        let start = f.string(from: Calendar(identifier:.gregorian).date(byAdding:.day,value:-210,to:Date())!)
        let url = URL(string: "https://stooq.com/q/d/l/?s=\(symbol.lowercased()).us&i=d&d1=\(start)")!
        let csv = try await get(url)
        let cells = TabularParser.csv(csv)
        guard let header = cells.first, header.map({$0.lowercased()}).contains("date") else { throw MonitorError.invalidData("Stooq未返回可识别的CSV：\(symbol)") }
        var data: [String:Double] = [:]
        for row in cells.dropFirst() {
            guard row.count >= 5, let d = DayClock.parse(row[0]), let c = Double(row[4]), c.isFinite && c > 0 else { continue }
            data[d] = c
        }
        let dates = data.keys.sorted()
        return QuoteHistory(symbol: symbol, dates: dates, closes: dates.compactMap { data[$0] })
    }
    public static func fetchQuote(_ symbol: String) async throws -> (QuoteHistory, String) {
        do { return (try await fetchYahoo(symbol), "Yahoo Finance日线") }
        catch { return (try await fetchStooq(symbol), "Stooq日线（Yahoo不可用时回退）") }
    }
}

public extension QuoteHistory {
    func through(_ date: String) -> QuoteHistory {
        let pairs = zip(dates, closes).filter { $0.0 <= date }
        return QuoteHistory(symbol: symbol, dates: pairs.map(\.0), closes: pairs.map(\.1))
    }
}
