import XCTest
@testable import StockbeeCore

/// 说明：`synthetic_sample.csv` 为虚构数据，仅测解析/边界逻辑；
/// `stockbee_official_2026-11-12.csv`、`nasdaq_*_2026-11-12.json`、`cboe_SPY_2026-11-12_trimmed.json`
/// 为 2026-11-12 10:09 UTC 在 GitHub Actions macOS runner 上实际抓取的原始响应（scripts/fetch-raw.sh）。
final class CoreTests: XCTestCase {
    func resource(_ name: String, _ ext: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext))
        return try String(contentsOf: url, encoding: .utf8)
    }
    func synthetic() throws -> BreadthSnapshot {
        let rows = try TabularParser.breadth(TabularParser.csv(try resource("synthetic_sample", "csv")))
        return BreadthSnapshot(sourceName: "fixture", sourceURL: "fixture", official: false, rows: rows)
    }
    func official() throws -> BreadthSnapshot {
        let rows = try TabularParser.breadth(TabularParser.csv(try resource("stockbee_official_2026-11-12", "csv")))
        return BreadthSnapshot(sourceName: "Stockbee 官网嵌入的 Google Sheet", sourceURL: "fixture", official: true, rows: rows)
    }
    func nasdaq(_ s: String) throws -> QuoteHistory {
        var h = try QuoteParser.parse(try resource("nasdaq_\(s)_2026-11-12", "json"), vendor: .nasdaq, symbol: s)
        h.vendor = DataFetcher.QuoteVendor.nasdaq.rawValue
        try QuoteParser.validate(h)
        return h
    }
    func realQuotes() throws -> [String: QuoteHistory] {
        var q: [String: QuoteHistory] = [:]
        for s in DataFetcher.etfSymbols { q[s] = try nasdaq(s).through("2026-11-11") }
        return q
    }

    // MARK: 原有测试（保留并按新接口调整）

    func testCSV() throws {
        XCTAssertEqual(TabularParser.csv("a,b\n\"c, d\",\"e\"\"f\""), [["a","b"],["c, d","e\"f"]])
    }
    func testCSVWithCRLF() throws {
        // Google Sheets 实际输出为 CRLF（交接版解析器在此处失败，导致官方数据完全无法读取）
        XCTAssertEqual(TabularParser.csv("a,b\r\n1,\"2,5\"\r\n"), [["a","b"],["1","2,5"]])
        XCTAssertTrue(try resource("stockbee_official_2026-11-12", "csv").contains("\r\n"))
    }
    func testParsesSyntheticRow() throws {
        let s = try synthetic()
        XCTAssertEqual(s.rows.count, 10)
        XCTAssertEqual(s.latest?.date, "2026-11-10")
        XCTAssertEqual(s.latest?.up4, 68)
        XCTAssertEqual(s.latest?.t2108, 57)
        XCTAssertEqual(s.quarterRatio ?? 0, 238.0/416.0, accuracy: 0.001)
        XCTAssertNotNil(s.ratio(3)); XCTAssertNotNil(s.ratio(5)); XCTAssertNotNil(s.ratio(10))
    }
    func testNoGuessingWithoutHeaders() throws {
        XCTAssertThrowsError(try TabularParser.breadth([["date","up","down"],["2026-11-10","20","40"]]))
    }
    func testIncompleteScoreIsNeverAFullScore() throws {
        let a = Scorer.assess(try synthetic(), [:])
        XCTAssertNil(a.total); XCTAssertNil(a.grade)
        XCTAssertEqual(a.availableMax, 65)
        XCTAssertTrue(a.vcp.contains("不完整"))
        XCTAssertFalse(a.blockers.isEmpty)
    }
    func testSyntheticFullScoreAndRange() throws {
        let s = try synthetic()
        var dates: [String] = []; var d = "2026-11-10"
        while dates.count < 70 { dates.insert(d, at: 0); d = TradingCalendar.previousSession(before: d)! }
        var quotes: [String: QuoteHistory] = [:]
        for symbol in DataFetcher.etfSymbols {
            let slope = symbol == "SMH" ? 1.5 : 1.0
            quotes[symbol] = QuoteHistory(symbol: symbol, dates: dates, closes: (0..<70).map { 100 + Double($0) * slope }, vendor: "v")
        }
        let a = Scorer.assess(s, quotes)
        XCTAssertNotNil(a.total)
        XCTAssertEqual(a.items.map(\.maxScore).reduce(0,+), 100)
        XCTAssertTrue((0...100).contains(a.total!))
        XCTAssertEqual(a.items[4].score, 25) // 两条上升直线：全部满足 + 1
    }
    func testHTMLTableParsing() throws {
        let html = "<table><tr><th>Date</th><th>Up 4% today</th><th>Down 4% today</th><th>Up 25% in a quarter</th><th>Down 25% in a quarter</th><th>T2108</th></tr><tr><td>Nov 10, 2026</td><td>68</td><td>124</td><td>238</td><td>416</td><td>57%</td></tr></table>"
        let days = try TabularParser.breadth(TabularParser.htmlTables(html)[0])
        XCTAssertEqual(days.count, 1); XCTAssertEqual(days[0].quarterDown, 416)
    }
    func testMissingRows() throws {
        var s = try synthetic()
        s.rows = Array(s.rows.prefix(2))
        XCTAssertNil(s.ratio(3))
        XCTAssertNil(Scorer.assess(s, [:]).total)
    }
    func testGapInRowsBlocksRatio() throws {
        var s = try official()
        s.rows.remove(at: 2) // 删掉一行 → 窗口不再是连续交易日
        XCTAssertNil(s.ratio(3))
        XCTAssertNil(s.ratio(10))
    }
    func testRelativeStrengthAndThrough() {
        var dates: [String] = []; var d = "2026-10-30"
        while dates.count < 35 { dates.insert(d, at: 0); d = TradingCalendar.previousSession(before: d)! }
        let spy = QuoteHistory(symbol: "SPY", dates: dates, closes: (0..<35).map { 100 + Double($0) })
        let xlk = QuoteHistory(symbol: "XLK", dates: dates, closes: (0..<35).map { 100 + Double($0) * 2 })
        XCTAssertGreaterThan(xlk.relativeGain(versus: spy) ?? 0, 0)
        XCTAssertEqual(spy.through(dates[20]).dates.count, 21)
    }
    func testDifferentDatesNeverCreateFullScore() throws {
        let s = try official()
        var quotes = try realQuotes()
        quotes["QQQ"] = quotes["QQQ"]!.through("2026-11-10") // QQQ 少一天
        let r = Scorer.assess(s, quotes)
        XCTAssertNil(r.total); XCTAssertNil(r.items[4].score); XCTAssertNotNil(r.items[6].score)
    }
    func testMixedVendorsBlockSector() throws {
        let s = try official()
        var quotes = try realQuotes()
        quotes["XLK"]!.vendor = "其他行情商"
        XCTAssertNil(Scorer.assess(s, quotes).items[6].score)
    }
    func testBadT2108Rejected() throws {
        let table = [["Date","Up 4% today","Down 4% today","Up 25% in quarter","Down 25% in quarter","T2108"],
                     ["Nov 10, 2026","68","124","238","416","105%"]]
        XCTAssertThrowsError(try TabularParser.breadth(table))
    }
    func testHeaderSplitAcrossRows() throws {
        let table = [["Date","Up","Down","Up","Down","T2108"],
                     ["","4% today","4% today","25% in quarter","25% in quarter",""],
                     ["Nov 10, 2026","68","124","238","416","57%"]]
        XCTAssertEqual(try TabularParser.breadth(table).first?.date, "2026-11-10")
    }

    // MARK: 真实官方数据回归

    func testRealOfficialSheetParses() throws {
        let s = try official()
        XCTAssertEqual(s.rows.count, 226)
        let l = try XCTUnwrap(s.latest)
        XCTAssertEqual(l.date, "2026-11-11")
        XCTAssertEqual(l.up4, 394); XCTAssertEqual(l.down4, 129)
        XCTAssertEqual(l.quarterUp, 977); XCTAssertEqual(l.quarterDown, 1341)
        XCTAssertEqual(l.t2108 ?? 0, 50.77, accuracy: 1e-9)
        XCTAssertEqual(l.reported5 ?? 0, 0.85, accuracy: 1e-9); XCTAssertEqual(l.reported10 ?? 0, 0.89, accuracy: 1e-9)
        XCTAssertEqual(l.universe, 6554)
        XCTAssertEqual(l.sp500 ?? 0, 7619.38, accuracy: 1e-6)
        XCTAssertEqual(s.rows.last?.date, "2025-12-18")
    }
    func testRatioDefinitionMatchesOfficialEveryRow() throws {
        let s = try official()
        var checked = 0
        for i in 0..<(s.rows.count - 10) {
            let sub = BreadthSnapshot(sourceName: "", sourceURL: "", official: true, rows: Array(s.rows[i...]))
            if let rep = sub.latest?.reported5 { XCTAssertEqual(sub.ratio(5)!, rep, accuracy: 0.0051, "5D \(sub.latest!.date)"); checked += 1 }
            if let rep = sub.latest?.reported10 { XCTAssertEqual(sub.ratio(10)!, rep, accuracy: 0.0051, "10D \(sub.latest!.date)"); checked += 1 }
        }
        XCTAssertEqual(checked, 432)
        XCTAssertTrue(s.ratioConsistency().isEmpty)
    }
    func testRealRatiosLatest() throws {
        let s = try official()
        XCTAssertEqual(s.ratio(3)!, 1291.0 / 570.0, accuracy: 1e-9)
        XCTAssertEqual(s.ratio(5)!, 1690.0 / 1995.0, accuracy: 1e-9)
        XCTAssertEqual(s.ratio(10)!, 3591.0 / 4046.0, accuracy: 1e-9)
        XCTAssertEqual(s.quarterRatio!, 977.0 / 1341.0, accuracy: 1e-9)
    }
    func testOfficialSheetDatesEqualNYSECalendar() throws {
        let s = try official()
        for (i, r) in s.rows.enumerated() {
            XCTAssertTrue(TradingCalendar.isTradingDay(r.date), r.date)
            if i + 1 < s.rows.count { XCTAssertEqual(TradingCalendar.previousSession(before: r.date), s.rows[i + 1].date) }
        }
    }
    func testRealDiscoveryFromOfficialPage() throws {
        let links = GoogleSheetDiscovery.sheetLinks(html: try resource("mm_iframe_excerpt_2026-11-12", "html"))
        XCTAssertEqual(links.count, 1)
        let urls = GoogleSheetDiscovery.csvURLs(links[0]).map(\.absoluteString)
        XCTAssertEqual(urls.first, "https://docs.google.com/spreadsheet/pub?key=0Am_cU8NLIU20dEhiQnVHN3Nnc3B1S3J6eGhKZFo0N3c&output=csv")
    }
    func testNewStyleDiscovery() {
        let html = "<iframe src=\"https://docs.google.com/spreadsheets/d/e/2PACX-abc/pubhtml?gid=2&amp;single=true\"></iframe>"
        let links = GoogleSheetDiscovery.sheetLinks(html: html)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(GoogleSheetDiscovery.csvURLs(links[0]).first?.absoluteString, "https://docs.google.com/spreadsheets/d/e/2PACX-abc/pub?output=csv&gid=2")
    }

    // MARK: 实时版 / 发布版交叉核对

    func testChannelsIdentical() throws {
        let rows = try official().rows
        XCTAssertTrue(ChannelCompare.differences(live: rows, published: rows).isEmpty)
    }
    func testChannelRevisionDetected() throws {
        // 2026-11-12 实际遇到：官网嵌入页面显示 387/127/0.84/976/1337，实时表格为 394/129/0.85/977/1341
        let live = try official().rows
        var pub = live
        pub[0].up4 = 387; pub[0].down4 = 127; pub[0].reported5 = 0.84; pub[0].quarterUp = 976; pub[0].quarterDown = 1337
        let d = ChannelCompare.differences(live: live, published: pub)
        XCTAssertEqual(d.count, 1)
        XCTAssertTrue(d[0].contains("2026-11-11") && d[0].contains("394/387") && d[0].contains("129/127") && d[0].contains("977/976"))
    }
    func testChannelPublishLag() throws {
        let live = try official().rows
        let pub = Array(live.dropFirst())
        XCTAssertTrue(ChannelCompare.differences(live: live, published: pub).first!.contains("2026-11-11"))
    }
    func testGvizHeaderParses() throws {
        // gviz 输出把两行表头合并为一行、所有字段加引号（2026-11-12 实测格式）
        let csv = "\"Date\",\"Primary Breadth Indicators Number of stocks up 4% plus today\",\"Number of stocks down 4% plus today\",\"5 day ratio\",\"10 day  ratio \",\"Number of stocks up 25% plus in a quarter\",\"Number of stocks down 25% + in a quarter\",\"Secondary Breadth Indicators Number of stocks up 25% + in a month\",\"Number of stocks down 25% + in a month\",\"Number of stocks up 50% + in a month\",\"Number of stocks down 50% + in a month\",\"Number of stocks up 13% + in 34 days\",\"Number of stocks down 13% + in 34 days\",\" Worden Common stock universe\",\"T2108 \",\"S&P\"\n\"11/11/2026\",\"394\",\"129\",\"0.85\",\"0.89\",\"977\",\"1341\",\"239\",\"155\",\"49\",\"24\",\"1881\",\"1620\",\"6554\",\"50.77\",\"7,619.38\"\n"
        let rows = try TabularParser.breadth(TabularParser.csv(csv))
        XCTAssertEqual(rows.first?.up4, 394); XCTAssertEqual(rows.first?.quarterDown, 1341); XCTAssertEqual(rows.first?.t2108, 50.77)
    }
    func testDocumentID() {
        XCTAssertEqual(GoogleSheetDiscovery.documentID("https://docs.google.com/spreadsheets/d/1O6OhS7ciA8zwfycBfGPbP2fWJnR0pn2UUvFZVDP9jpE/pub?output=html&widget=true"),
                       "1O6OhS7ciA8zwfycBfGPbP2fWJnR0pn2UUvFZVDP9jpE")
        XCTAssertNil(GoogleSheetDiscovery.documentID("https://docs.google.com/spreadsheets/d/e/2PACX-1vabcdefghijklmnopqrstuvwxyz/pubhtml"))
        XCTAssertNil(GoogleSheetDiscovery.documentID(GoogleSheetDiscovery.lastVerifiedEmbed))
    }

    // MARK: 行情解析与完整评分（真实数据）

    func testNasdaqParser() throws {
        let spy = try nasdaq("SPY")
        XCTAssertEqual(spy.lastDate, "2026-11-11")
        XCTAssertEqual(spy.lastClose ?? 0, 759.81, accuracy: 1e-9)
        XCTAssertEqual(spy.dates.count, 207)
    }
    func testCboeParserAndLag() throws {
        let h = try QuoteParser.parse(try resource("cboe_SPY_2026-11-12_trimmed", "json"), vendor: .cboe, symbol: "SPY")
        XCTAssertEqual(h.lastDate, "2026-11-10") // Cboe 文件比 Nasdaq 晚一天更新
        let n = try nasdaq("SPY")
        let nm = Dictionary(uniqueKeysWithValues: zip(n.dates, n.closes))
        XCTAssertEqual(nm["2026-11-10"]!, h.closes.last!, accuracy: 0.01) // 两家同日收盘一致
    }
    func testRealFullAssessment() throws {
        let a = Scorer.assess(try official(), try realQuotes())
        XCTAssertEqual(a.items.map { $0.score ?? -1 }, [8, 0, 0, 5, 0, 12, 3])
        XCTAssertEqual(a.total, 28)
        XCTAssertEqual(a.grade, "D")
        XCTAssertEqual(a.gapToIdeal, 52)
        XCTAssertEqual(a.vcp, Scorer.vcpAdvice("D")); XCTAssertEqual(a.htf, Scorer.htfAdvice("D"))
        XCTAssertEqual(a.topDeductions.first?.name, "SPY/QQQ 指数趋势")
        XCTAssertTrue(a.signals.contains { $0.text.contains("2026-11-05") && $0.text.contains("1269") })
    }
    func testCboeLaggingQuotesNeverScore() throws {
        var quotes = try realQuotes()
        quotes["SPY"] = quotes["SPY"]!.through("2026-11-10")
        let a = Scorer.assess(try official(), quotes)
        XCTAssertNil(a.total); XCTAssertNil(a.items[4].score); XCTAssertNil(a.items[6].score)
    }
    func testBlockersPreventGrade() throws {
        let a = Scorer.assess(try official(), try realQuotes(), blockers: ["离线缓存"])
        XCTAssertNil(a.total); XCTAssertNil(a.grade)
        XCTAssertEqual(a.partial, 28)
        XCTAssertTrue(a.vcp.contains("不完整"))
    }
    func testValidateRejectsSplitLikeJump() {
        let d = ["2026-11-09", "2026-11-10", "2026-11-11"]
        XCTAssertThrowsError(try QuoteParser.validate(QuoteHistory(symbol: "X", dates: d, closes: [100, 50, 51])))
        XCTAssertThrowsError(try QuoteParser.validate(QuoteHistory(symbol: "X", dates: ["2026-11-07", "2026-11-09"], closes: [1, 1]))) // 周六
    }

    // MARK: 评分边界

    func testGradeBoundaries() {
        let cases: [(Int, String)] = [(100,"A"),(80,"A"),(79,"B"),(65,"B"),(64,"C"),(45,"C"),(44,"D"),(0,"D")]
        for (n, g) in cases { XCTAssertEqual(Scorer.grade(for: n), g, "\(n)") }
        XCTAssertTrue(Scorer.vcpAdvice("A").contains("按计划参与")); XCTAssertTrue(Scorer.htfAdvice("A").contains("可参与"))
        XCTAssertTrue(Scorer.vcpAdvice("B").contains("小仓")); XCTAssertTrue(Scorer.htfAdvice("B").contains("极强"))
        XCTAssertTrue(Scorer.vcpAdvice("C").contains("观察")); XCTAssertTrue(Scorer.htfAdvice("C").contains("暂停"))
        XCTAssertTrue(Scorer.vcpAdvice("D").contains("暂停")); XCTAssertTrue(Scorer.htfAdvice("D").contains("暂停"))
    }
    func testStepThresholds() {
        XCTAssertEqual([1.5, 1.49, 1.0, 0.99, 0.7, 0.69].map(Scorer.quarterPoints), [20, 15, 15, 8, 8, 0])
        XCTAssertEqual([2.0, 1.99, 1.3, 1.29, 1.0, 0.99].map(Scorer.r10Points), [15, 11, 11, 7, 7, 0])
        XCTAssertEqual([2.0, 1.99, 1.3, 1.29, 1.0, 0.99].map(Scorer.r5Points), [5, 4, 4, 3, 3, 0])
        XCTAssertEqual([1.5, 1.49, 1.0, 0.99].map(Scorer.r3Points), [5, 3, 3, 0])
        XCTAssertEqual([70, 69.99, 60, 59.99, 50, 49.99, 40, 39.99].map(Scorer.t2108Points), [20, 17, 17, 12, 12, 7, 7, 0])
    }
    func testExtremeMarkets() throws {
        // 极端行情：全部下跌 → 分母不为0时比率趋近0；4% Down 为 0 时比率不可计算（N/A，不是满分也不是0分）
        let crash = (0..<10).map { i -> BreadthDay in
            var d = "2026-11-11"; for _ in 0..<i { d = TradingCalendar.previousSession(before: d)! }
            return BreadthDay(date: d, up4: 0, down4: 1500, quarterUp: 50, quarterDown: 3000, t2108: 3)
        }
        let a = Scorer.assess(BreadthSnapshot(sourceName: "", sourceURL: "", official: true, rows: crash), [:])
        XCTAssertEqual(a.items[0].score, 0); XCTAssertEqual(a.items[1].score, 0); XCTAssertEqual(a.items[5].score, 0)
        XCTAssertNil(a.total)
        XCTAssertTrue(a.signals.contains { $0.kind == .extreme })
        let melt = crash.map { BreadthDay(date: $0.date, up4: 900, down4: 0, quarterUp: 2000, quarterDown: 0, t2108: 95) }
        let b = Scorer.assess(BreadthSnapshot(sourceName: "", sourceURL: "", official: true, rows: melt), [:])
        XCTAssertNil(b.items[0].score); XCTAssertNil(b.items[1].score); XCTAssertEqual(b.items[5].score, 20)
    }

    // MARK: 交易日历与时效

    func testHolidays2026() {
        let h = TradingCalendar.holidays(2026)
        for d in ["2026-01-01","2026-01-19","2026-02-16","2026-04-03","2026-05-25","2026-06-19","2026-07-03","2026-09-07","2026-11-26","2026-12-25"] {
            XCTAssertTrue(h.contains(d), d)
        }
        XCTAssertEqual(h.count, 10)
        XCTAssertTrue(TradingCalendar.holidays(2027).contains("2027-12-24")) // 圣诞落周六 → 周五
        XCTAssertTrue(TradingCalendar.isTradingDay("2027-12-31"))           // 元旦落周六不提前
        XCTAssertTrue(TradingCalendar.isTradingDay("2026-11-11"))           // 退伍军人节股市开市
    }
    func testFreshness() {
        func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
        XCTAssertEqual(Freshness.evaluate(dataDate: "2026-11-11", now: at("2026-11-12T10:09:00Z")), .current)
        XCTAssertEqual(Freshness.evaluate(dataDate: "2026-11-11", now: at("2026-11-12T22:00:00Z")), .awaitingPublish)
        XCTAssertEqual(Freshness.evaluate(dataDate: "2026-11-11", now: at("2026-11-16T17:00:00Z")), .stale(2))
        XCTAssertEqual(Freshness.evaluate(dataDate: "2026-11-13", now: at("2026-11-16T10:00:00Z")), .current)   // 周一盘前：上周五为最新
        XCTAssertEqual(Freshness.evaluate(dataDate: "2026-11-25", now: at("2026-11-27T15:00:00Z")), .current)   // 感恩节次日盘中
        XCTAssertEqual(Freshness.evaluate(dataDate: "2026-11-12", now: at("2026-11-12T10:00:00Z")), .future)
        XCTAssertFalse(Freshness.stale(2).usableForScoring)
        XCTAssertTrue(Freshness.awaitingPublish.usableForScoring)
    }
}
