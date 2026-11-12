import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MonitorError: LocalizedError {
    case invalidData(String)
    case unsupportedSource(String)
    case missingData(String)
    public var errorDescription: String? {
        switch self {
        case .invalidData(let s), .unsupportedSource(let s), .missingData(let s): return s
        }
    }
}

// MARK: - 市场广度（Stockbee Market Monitor 表格的一行）

/// 一个美股交易日（America/New_York）的 Stockbee 广度数据。字段与官方 Google Sheet 列一一对应（2026-11-12 实测列名）。
public struct BreadthDay: Identifiable, Codable, Equatable {
    public var date: String          // yyyy-MM-dd
    public var up4: Int              // Number of stocks up 4% plus today
    public var down4: Int            // Number of stocks down 4% plus today
    public var quarterUp: Int        // Number of stocks up 25% plus in a quarter
    public var quarterDown: Int      // Number of stocks down 25% + in a quarter
    public var t2108: Double?        // T2108：Worden 普通股中收盘高于 40 日均线的百分比（0–100）
    public var reported5: Double?    // 官方表格公布的 5 day ratio
    public var reported10: Double?   // 官方表格公布的 10 day ratio
    public var universe: Int?        // Worden Common stock universe（股票池数量）
    public var sp500: Double?        // 表格中的 S&P 500 指数收盘
    public var id: String { date }
    public init(date: String, up4: Int, down4: Int, quarterUp: Int, quarterDown: Int, t2108: Double?,
                reported5: Double? = nil, reported10: Double? = nil, universe: Int? = nil, sp500: Double? = nil) {
        self.date = date; self.up4 = up4; self.down4 = down4
        self.quarterUp = quarterUp; self.quarterDown = quarterDown
        self.t2108 = t2108; self.reported5 = reported5; self.reported10 = reported10
        self.universe = universe; self.sp500 = sp500
    }
}

public struct BreadthSnapshot: Codable {
    public var sourceName: String
    public var sourceURL: String
    public var official: Bool
    public var rows: [BreadthDay] // 按交易日降序（最新在前）
    public var fetchedAt: Date
    public var discoveredLinks: [String]?   // 本次从官网页面发现的表格地址
    public var note: String?                // 取数过程说明（如官网页面暂不可达而使用已知地址）
    public init(sourceName: String, sourceURL: String, official: Bool, rows: [BreadthDay], fetchedAt: Date = Date(),
                discoveredLinks: [String]? = nil, note: String? = nil) {
        self.sourceName = sourceName; self.sourceURL = sourceURL; self.official = official; self.rows = rows; self.fetchedAt = fetchedAt
        self.discoveredLinks = discoveredLinks; self.note = note
    }
    public var latest: BreadthDay? { rows.first }

    /// N 日比率 = 最近 N 个交易日 4% Up 合计 ÷ 4% Down 合计（与官方 5/10 day ratio 定义一致，已用 2026-09-21~11-11 实测数据核对）。
    public func ratio(_ n: Int, offset: Int = 0) -> Double? {
        guard n > 0, rows.count >= n + offset else { return nil }
        let window = rows[offset..<(offset + n)]
        guard isConsecutive(Array(window)) else { return nil }
        let up = window.reduce(0) { $0 + $1.up4 }
        let down = window.reduce(0) { $0 + $1.down4 }
        return down > 0 ? Double(up) / Double(down) : nil
    }
    /// Quarter Ratio = 季度涨 ≥25% 股票数 ÷ 季度跌 ≥25% 股票数。
    public func quarterRatio(offset: Int = 0) -> Double? {
        guard rows.count > offset, rows[offset].quarterDown > 0 else { return nil }
        return Double(rows[offset].quarterUp) / Double(rows[offset].quarterDown)
    }
    public var quarterRatio: Double? { quarterRatio() }

    /// 窗口内日期必须是交易日历上连续的交易日，否则（表格缺行）不出比率。
    func isConsecutive(_ days: [BreadthDay]) -> Bool {
        guard days.count > 1 else { return true }
        for i in 0..<(days.count - 1) {
            guard let prev = TradingCalendar.previousSession(before: days[i].date), prev == days[i + 1].date else { return false }
        }
        return true
    }
    /// 官方公布 5D/10D 与按日度数据复算值比较（官方保留 2 位小数，容差 0.006）。
    public func ratioConsistency() -> [String] {
        var problems: [String] = []
        if let rep = latest?.reported5, let comp = ratio(5), abs(rep - comp) > 0.006 {
            problems.append("5D 官方公布值 \(String(format:"%.2f", rep)) 与日度复算 \(String(format:"%.3f", comp)) 不一致")
        }
        if let rep = latest?.reported10, let comp = ratio(10), abs(rep - comp) > 0.006 {
            problems.append("10D 官方公布值 \(String(format:"%.2f", rep)) 与日度复算 \(String(format:"%.3f", comp)) 不一致")
        }
        return problems
    }
}

// MARK: - ETF 日线

public struct QuoteHistory: Codable, Equatable {
    public let symbol: String
    public let dates: [String]
    public let closes: [Double]
    public var vendor: String
    public init(symbol: String, dates: [String], closes: [Double], vendor: String = "") {
        self.symbol = symbol; self.dates = dates; self.closes = closes; self.vendor = vendor
    }
    public var lastDate: String? { dates.last }
    public var lastClose: Double? { closes.last }
    /// 简单移动平均；offset=k 表示截至倒数第 k+1 根 K 线。
    public func sma(_ n: Int, offset: Int = 0) -> Double? {
        guard n > 0, closes.count >= n + offset else { return nil }
        return closes[(closes.count - n - offset)..<(closes.count - offset)].reduce(0,+) / Double(n)
    }
    /// 相对 SPY 的 N 个共同交易日价格比变化：(A_t/B_t) / (A_{t-N}/B_{t-N}) - 1。
    public func relativeGain(versus benchmark: QuoteHistory, lookback: Int = 20) -> Double? {
        let a = Dictionary(zip(dates, closes), uniquingKeysWith: { _, last in last })
        let b = Dictionary(zip(benchmark.dates, benchmark.closes), uniquingKeysWith: { _, last in last })
        let common = Set(a.keys).intersection(b.keys).sorted()
        guard common.count > lookback,
              let last = common.last, let ae = a[last], let be = b[last] else { return nil }
        let first = common[common.count - 1 - lookback]
        guard let ai = a[first], let bi = b[first], ai > 0, bi > 0, be > 0 else { return nil }
        return (ae / be) / (ai / bi) - 1
    }
    public func through(_ date: String) -> QuoteHistory {
        let pairs = zip(dates, closes).filter { $0.0 <= date }
        return QuoteHistory(symbol: symbol, dates: pairs.map(\.0), closes: pairs.map(\.1), vendor: vendor)
    }
}

// MARK: - 交易日历（NYSE 常规休市日，按 America/New_York）

public enum TradingCalendar {
    static var gregorian: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c
    }()
    static func comps(_ s: String) -> (Int, Int, Int)? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? (p[0], p[1], p[2]) : nil
    }
    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date? { gregorian.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) }
    static func string(_ d: Date) -> String {
        let c = gregorian.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func weekday(_ y: Int, _ m: Int, _ d: Int) -> Int { gregorian.component(.weekday, from: date(y, m, d)!) } // 1=周日
    static func nthWeekday(_ y: Int, _ m: Int, _ wd: Int, _ n: Int) -> Int {
        var count = 0
        for d in 1...31 { guard date(y, m, d).map({ gregorian.component(.month, from: $0) == m }) == true else { break }
            if weekday(y, m, d) == wd { count += 1; if count == n { return d } } }
        return 0
    }
    static func lastWeekday(_ y: Int, _ m: Int, _ wd: Int) -> Int {
        var last = 0
        for d in 1...31 { guard date(y, m, d).map({ gregorian.component(.month, from: $0) == m }) == true else { break }
            if weekday(y, m, d) == wd { last = d } }
        return last
    }
    static func easter(_ y: Int) -> (Int, Int) { // 匿名公历算法
        let a = y % 19, b = y / 100, c = y % 100, d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30, i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        return ((h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1)
    }
    /// 固定日期节假日的观察日：周六→周五，周日→周一（元旦落在周六时不提前到上一年周五）。
    static func observed(_ y: Int, _ m: Int, _ d: Int, newYear: Bool = false) -> String? {
        let wd = weekday(y, m, d)
        guard let base = date(y, m, d) else { return nil }
        if wd == 7 { return newYear ? nil : string(gregorian.date(byAdding: .day, value: -1, to: base)!) }
        if wd == 1 { return string(gregorian.date(byAdding: .day, value: 1, to: base)!) }
        return string(base)
    }
    public static func holidays(_ y: Int) -> Set<String> {
        var s = Set<String>()
        func add(_ m: Int, _ d: Int) { s.insert(String(format: "%04d-%02d-%02d", y, m, d)) }
        if let x = observed(y, 1, 1, newYear: true) { s.insert(x) }
        add(1, nthWeekday(y, 1, 2, 3))      // MLK：1 月第 3 个周一
        add(2, nthWeekday(y, 2, 2, 3))      // 总统日：2 月第 3 个周一
        let (em, ed) = easter(y)
        if let e = date(y, em, ed), let gf = gregorian.date(byAdding: .day, value: -2, to: e) { s.insert(string(gf)) } // 耶稣受难日
        add(5, lastWeekday(y, 5, 2))        // 阵亡将士纪念日
        if y >= 2022, let x = observed(y, 6, 19) { s.insert(x) }
        if let x = observed(y, 7, 4) { s.insert(x) }
        add(9, nthWeekday(y, 9, 2, 1))      // 劳工节
        add(11, nthWeekday(y, 11, 5, 4))    // 感恩节
        if let x = observed(y, 12, 25) { s.insert(x) }
        return s
    }
    public static func isTradingDay(_ day: String) -> Bool {
        guard let (y, m, d) = comps(day), let dt = date(y, m, d) else { return false }
        let wd = gregorian.component(.weekday, from: dt)
        if wd == 1 || wd == 7 { return false }
        return !holidays(y).contains(day) && !holidays(y + 1).contains(day)
    }
    public static func previousSession(before day: String) -> String? {
        guard let (y, m, d) = comps(day), var dt = date(y, m, d) else { return nil }
        for _ in 0..<15 {
            dt = gregorian.date(byAdding: .day, value: -1, to: dt)!
            let s = string(dt)
            if isTradingDay(s) { return s }
        }
        return nil
    }
    /// `now` 时刻已经收盘（美东 16:00 后）的最近一个交易日。
    public static func lastClosedSession(at now: Date) -> String {
        let today = string(now)
        let hour = gregorian.component(.hour, from: now)
        if isTradingDay(today) && hour >= 16 { return today }
        return previousSession(before: today) ?? today
    }
    /// 从 older 到 newer 之间相隔几个交易日（newer 本身计入；相同为 0）。
    public static func sessionsBetween(_ older: String, _ newer: String) -> Int {
        guard older < newer else { return 0 }
        var n = 0, cur = newer
        while cur > older, n < 400 { guard let p = previousSession(before: cur) else { break }; cur = p; n += 1 }
        return n
    }
}

// MARK: - 数据时效

public enum Freshness: Equatable {
    case current            // 已是最近一个收盘交易日
    case awaitingPublish    // 落后 1 个交易日：通常为收盘后 Stockbee 尚未更新，可用于评分
    case stale(Int)         // 落后 ≥2 个交易日：过期，禁止完整评分
    case future             // 数据日期晚于最近收盘日：异常

    public static func evaluate(dataDate: String, now: Date = Date()) -> Freshness {
        let expected = TradingCalendar.lastClosedSession(at: now)
        if dataDate > expected { return .future }
        let lag = TradingCalendar.sessionsBetween(dataDate, expected)
        switch lag { case 0: return .current; case 1: return .awaitingPublish; default: return .stale(lag) }
    }
    public var usableForScoring: Bool { switch self { case .current, .awaitingPublish: return true; default: return false } }
    public var label: String {
        switch self {
        case .current: return "最新"
        case .awaitingPublish: return "最新已发布（最近一个交易日尚未发布）"
        case .stale(let n): return "过期（落后 \(n) 个交易日）"
        case .future: return "日期异常（晚于最近收盘日）"
        }
    }
}

// MARK: - 评分

public struct ScoreItem: Identifiable {
    public let name: String
    public let maxScore: Int
    public let score: Int?
    public let value: String        // 当前读数（展示用）
    public let rule: String         // 阶梯规则
    public let detail: String       // 计算过程 / 缺失原因
    public var id: String { name }
    public var deduction: Int? { score.map { maxScore - $0 } }
}

public struct Signal: Identifiable {
    public enum Kind { case improving, deteriorating, extreme, neutral }
    public let kind: Kind
    public let text: String
    public var id: String { text }
}

public struct Assessment {
    public let items: [ScoreItem]
    public let total: Int?          // 任一模块缺失或存在阻断原因时为 nil
    public let partial: Int
    public let availableMax: Int
    public let grade: String?
    public let vcp: String
    public let htf: String
    public let blockers: [String]
    public let signals: [Signal]
    public var gapToIdeal: Int? { total.map { max(0, 80 - $0) } }
    public var topDeductions: [ScoreItem] {
        items.filter { ($0.deduction ?? 0) > 0 }.sorted { ($0.deduction ?? 0) > ($1.deduction ?? 0) }
    }
}

public enum Scorer {
    public static let ruleVersion = "评分规则 v1.0（继承交接版阈值，2026-11-12）"

    public static func grade(for total: Int) -> String { total >= 80 ? "A" : (total >= 65 ? "B" : (total >= 45 ? "C" : "D")) }
    public static func vcpAdvice(_ grade: String?) -> String {
        switch grade {
        case "A": return "按计划参与；仍须满足个股 Pivot、放量突破和止损条件"
        case "B": return "精选领涨股，小仓位试单"
        case "C": return "原则上观察，不追突破"
        case "D": return "暂停新开 VCP 突破仓位"
        default: return "数据不完整，暂不依据环境评分开新仓"
        }
    }
    public static func htfAdvice(_ grade: String?) -> String {
        switch grade {
        case "A": return "可参与；等待有效 HTF（高紧旗形）突破"
        case "B": return "仅限极强领涨股，严格控制风险"
        case "C", "D": return "暂停新开 HTF 仓位"
        default: return "数据不完整，暂停基于评分的 HTF 信号"
        }
    }
    static func f2(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "N/A" }

    static func quarterPoints(_ q: Double) -> Int { q >= 1.5 ? 20 : (q >= 1.0 ? 15 : (q >= 0.7 ? 8 : 0)) }
    static func r10Points(_ r: Double) -> Int { r >= 2 ? 15 : (r >= 1.3 ? 11 : (r >= 1 ? 7 : 0)) }
    static func r5Points(_ r: Double) -> Int { r >= 2 ? 5 : (r >= 1.3 ? 4 : (r >= 1 ? 3 : 0)) }
    static func r3Points(_ r: Double) -> Int { r >= 1.5 ? 5 : (r >= 1 ? 3 : 0) }
    static func t2108Points(_ t: Double) -> Int { t >= 70 ? 20 : (t >= 60 ? 17 : (t >= 50 ? 12 : (t >= 40 ? 7 : 0))) }

    /// - Parameters:
    ///   - blockers: 来自数据层的阻断原因（过期、离线缓存、非官方源等）。存在任意阻断时不发布总分和等级。
    public static func assess(_ snapshot: BreadthSnapshot?, _ quotes: [String: QuoteHistory], blockers extra: [String] = []) -> Assessment {
        var blockers = extra
        let missing = "无广度数据"
        let q = snapshot?.quarterRatio
        let r10 = snapshot?.ratio(10), r5 = snapshot?.ratio(5), r3 = snapshot?.ratio(3)
        let latest = snapshot?.latest
        var items: [ScoreItem] = [
            ScoreItem(name: "Stockbee Quarter Ratio", maxScore: 20, score: q.map(quarterPoints), value: f2(q),
                      rule: "≥1.5:20 ≥1.0:15 ≥0.7:8 其余0",
                      detail: latest.map { q == nil ? "季度下跌数为0，无法计算" : "\($0.quarterUp) ÷ \($0.quarterDown)" } ?? missing),
            ScoreItem(name: "Stockbee 10D Ratio", maxScore: 15, score: r10.map(r10Points), value: f2(r10),
                      rule: "≥2.0:15 ≥1.3:11 ≥1.0:7 其余0",
                      detail: r10 == nil ? "需要连续10个交易日数据" : "近10个交易日 4%Up 合计 ÷ 4%Down 合计" + (latest?.reported10.map { "；官方公布 \(f2($0))" } ?? "")),
            ScoreItem(name: "Stockbee 5D Ratio", maxScore: 5, score: r5.map(r5Points), value: f2(r5),
                      rule: "≥2.0:5 ≥1.3:4 ≥1.0:3 其余0",
                      detail: r5 == nil ? "需要连续5个交易日数据" : "近5个交易日 4%Up 合计 ÷ 4%Down 合计" + (latest?.reported5.map { "；官方公布 \(f2($0))" } ?? "")),
            ScoreItem(name: "Stockbee 3D Ratio", maxScore: 5, score: r3.map(r3Points), value: f2(r3),
                      rule: "≥1.5:5 ≥1.0:3 其余0",
                      detail: r3 == nil ? "需要连续3个交易日数据" : "近3个交易日 4%Up 合计 ÷ 4%Down 合计（官方未公布，按同一定义复算）")
        ]

        // SPY/QQQ 趋势：两只 ETF 都必须有截至广度同一交易日的行情。
        var trend: Int? = nil
        var trendDetail = "缺少与广度同日的 SPY/QQQ 行情"
        var trendValue = "N/A"
        if let session = latest?.date, let spy = quotes["SPY"], let qqq = quotes["QQQ"], spy.lastDate == session, qqq.lastDate == session {
            func component(_ h: QuoteHistory) -> (Int, String)? {
                guard let close = h.lastClose, let ma20 = h.sma(20), let ma50 = h.sma(50), let prior20 = h.sma(20, offset: 5) else { return nil }
                let a = close > ma20 ? 4 : 0, b = close > ma50 ? 5 : 0, c = ma20 > prior20 ? 3 : 0
                return (a + b + c, "\(h.symbol) 收盘\(f2(close)) MA20 \(f2(ma20))\(a > 0 ? "✓" : "✗") MA50 \(f2(ma50))\(b > 0 ? "✓" : "✗") MA20斜率\(c > 0 ? "↑✓" : "↓✗")")
            }
            if let (a, da) = component(spy), let (b, db) = component(qqq) {
                trend = a + b + ((a == 12 && b == 12) ? 1 : 0)
                trendDetail = da + "；" + db
                trendValue = "SPY \(a)/12 · QQQ \(b)/12"
            } else { trendDetail = "SPY/QQQ 历史不足 55 个交易日" }
        }
        items.append(ScoreItem(name: "SPY/QQQ 指数趋势", maxScore: 25, score: trend, value: trendValue,
                               rule: "每只：收盘>MA20 +4，收盘>MA50 +5，MA20 高于5日前 +3；两只全满足再 +1", detail: trendDetail))

        let t = latest?.t2108
        items.append(ScoreItem(name: "T2108 市场广度", maxScore: 20, score: t.map(t2108Points), value: t.map { String(format: "%.2f%%", $0) } ?? "N/A",
                               rule: "≥70:20 ≥60:17 ≥50:12 ≥40:7 其余0",
                               detail: t == nil ? "官方表格未提供 T2108" : "Stockbee 表格 T2108 列（Worden 普通股高于40日均线占比）；非 Russell 3000 口径"))

        var sector: Int? = nil
        var sectorDetail = "缺少与广度同日、同一行情商的 SPY/XLK/SMH/XLY 行情"
        var sectorValue = "N/A"
        if let session = latest?.date, let spy = quotes["SPY"], let xlk = quotes["XLK"], let smh = quotes["SMH"], let xly = quotes["XLY"],
           ([spy, xlk, smh, xly].allSatisfy { $0.lastDate == session }),
           Set([spy.vendor, xlk.vendor, smh.vendor, xly.vendor]).count == 1 {
            if let a = xlk.relativeGain(versus: spy), let b = smh.relativeGain(versus: spy), let c = xly.relativeGain(versus: spy) {
                sector = (a > 0 ? 3 : 0) + (b > 0 ? 4 : 0) + (c > 0 ? 3 : 0)
                func pct(_ x: Double) -> String { String(format: "%+.2f%%", x * 100) }
                sectorDetail = "20日相对SPY：XLK \(pct(a)) · SMH \(pct(b)) · XLY \(pct(c))"
                sectorValue = "XLK\(a > 0 ? "✓" : "✗") SMH\(b > 0 ? "✓" : "✗") XLY\(c > 0 ? "✓" : "✗")"
            } else { sectorDetail = "共同交易日不足 21 个" }
        }
        items.append(ScoreItem(name: "XLK/SMH/XLY 板块领导力", maxScore: 10, score: sector, value: sectorValue,
                               rule: "近20个共同交易日相对SPY走强：XLK +3、SMH +4、XLY +3", detail: sectorDetail))

        for item in items where item.score == nil { blockers.append("\(item.name)：\(item.detail)") }
        let sum = items.compactMap(\.score).reduce(0, +)
        let avail = items.filter { $0.score != nil }.reduce(0) { $0 + $1.maxScore }
        let complete = items.allSatisfy { $0.score != nil } && extra.isEmpty
        let total = complete ? sum : nil
        let g = total.map(grade(for:))
        return Assessment(items: items, total: total, partial: sum, availableMax: avail, grade: g,
                          vcp: vcpAdvice(g), htf: htfAdvice(g), blockers: blockers, signals: signals(snapshot))
    }

    /// 改善/恶化信号：只比较官方原始数据的变化，并标注 Stockbee 页面提及的极值（4% Down ≥700 为大规模抛售、T2108 <20 超卖）。
    public static func signals(_ s: BreadthSnapshot?) -> [Signal] {
        guard let s, let l = s.latest else { return [] }
        var out: [Signal] = []
        func trend(_ name: String, _ now: Double?, _ before: Double?, _ eps: Double) {
            guard let now, let before else { return }
            let d = now - before
            if abs(d) < eps { out.append(Signal(kind: .neutral, text: "\(name) 较5个交易日前持平（\(f2(before)) → \(f2(now))）")) }
            else { out.append(Signal(kind: d > 0 ? .improving : .deteriorating, text: "\(name) 较5个交易日前\(d > 0 ? "改善" : "恶化")：\(f2(before)) → \(f2(now))")) }
        }
        trend("10D Ratio", s.ratio(10), s.ratio(10, offset: 5), 0.05)
        trend("Quarter Ratio", s.quarterRatio(), s.quarterRatio(offset: 5), 0.03)
        if s.rows.count > 5 { trend("T2108", l.t2108, s.rows[5].t2108, 2) }
        if l.down4 >= 700 { out.append(Signal(kind: .extreme, text: "当日 4% Down = \(l.down4)（≥700，Stockbee 视为大规模抛售日）")) }
        if let w = s.rows.prefix(10).first(where: { $0.down4 >= 700 }), w.date != l.date {
            out.append(Signal(kind: .extreme, text: "近10日内出现大规模抛售日：\(w.date) 4% Down = \(w.down4)"))
        }
        if let t = l.t2108, t < 20 { out.append(Signal(kind: .extreme, text: "T2108 = \(f2(t))（<20，超卖区）")) }
        if let t = l.t2108, t > 70 { out.append(Signal(kind: .extreme, text: "T2108 = \(f2(t))（>70，偏热区）")) }
        if l.up4 >= 500 { out.append(Signal(kind: .improving, text: "当日 4% Up = \(l.up4)（≥500，强势上攻日）")) }
        return out
    }
}

public enum DayClock {
    public static func nyDate(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    public static func parse(_ text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{00a0}", with: " ")
        if clean.range(of: #"^20\d\d-\d\d-\d\d$"#, options: .regularExpression) != nil { return clean }
        let formats = ["M/d/yyyy", "MM/dd/yyyy", "MMM d, yyyy", "MMM dd, yyyy", "yyyy/M/d", "d MMM yyyy"]
        let input = DateFormatter(); input.locale = Locale(identifier: "en_US_POSIX"); input.timeZone = TimeZone(secondsFromGMT: 0)
        input.isLenient = false
        let out = DateFormatter(); out.locale = Locale(identifier: "en_US_POSIX"); out.timeZone = TimeZone(secondsFromGMT: 0); out.dateFormat = "yyyy-MM-dd"
        for fmt in formats {
            input.dateFormat = fmt
            if let d = input.date(from: clean) {
                let s = out.string(from: d)
                if s.hasPrefix("20") { return s }
            }
        }
        return nil
    }
}
