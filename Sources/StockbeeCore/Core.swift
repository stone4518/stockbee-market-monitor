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

public struct BreadthDay: Identifiable, Codable, Equatable {
    public var date: String // yyyy-MM-dd, America/New_York trading-session date
    public var up4: Int
    public var down4: Int
    public var quarterUp: Int
    public var quarterDown: Int
    public var t2108: Double?
    public var reported5: Double?
    public var reported10: Double?
    public var id: String { date }
    public init(date: String, up4: Int, down4: Int, quarterUp: Int, quarterDown: Int, t2108: Double?, reported5: Double? = nil, reported10: Double? = nil) {
        self.date = date; self.up4 = up4; self.down4 = down4
        self.quarterUp = quarterUp; self.quarterDown = quarterDown
        self.t2108 = t2108; self.reported5 = reported5; self.reported10 = reported10
    }
}

public struct BreadthSnapshot: Codable {
    public var sourceName: String
    public var sourceURL: String
    public var official: Bool
    public var rows: [BreadthDay] // newest first, by trading-session date
    public var fetchedAt: Date
    public init(sourceName: String, sourceURL: String, official: Bool, rows: [BreadthDay], fetchedAt: Date = Date()) {
        self.sourceName = sourceName; self.sourceURL = sourceURL; self.official = official; self.rows = rows; self.fetchedAt = fetchedAt
    }
    public var latest: BreadthDay? { rows.first }
    public func ratio(_ n: Int) -> Double? {
        guard rows.count >= n else { return nil }
        let window = rows.prefix(n)
        let up = window.reduce(0) { $0 + $1.up4 }
        let down = window.reduce(0) { $0 + $1.down4 }
        return down > 0 ? Double(up) / Double(down) : nil
    }
    public var quarterRatio: Double? {
        guard let l = latest, l.quarterDown > 0 else { return nil }
        return Double(l.quarterUp) / Double(l.quarterDown)
    }
    public func ratioConsistency() -> [String] {
        var problems: [String] = []
        if let rep = latest?.reported5, let comp = ratio(5), abs(rep - comp) > 0.08 {
            problems.append("5D公布值与4%日度汇总不一致：\(String(format:"%.2f", rep)) vs \(String(format:"%.2f", comp))")
        }
        if let rep = latest?.reported10, let comp = ratio(10), abs(rep - comp) > 0.08 {
            problems.append("10D公布值与4%日度汇总不一致：\(String(format:"%.2f", rep)) vs \(String(format:"%.2f", comp))")
        }
        return problems
    }
}

public struct QuoteHistory: Codable {
    public let symbol: String
    public let dates: [String]
    public let closes: [Double]
    public init(symbol: String, dates: [String], closes: [Double]) {
        self.symbol = symbol; self.dates = dates; self.closes = closes
    }
    public var lastDate: String? { dates.last }
    public var lastClose: Double? { closes.last }
    public func sma(_ n: Int, offset: Int = 0) -> Double? {
        guard closes.count >= n + offset else { return nil }
        return closes[(closes.count - n - offset)..<(closes.count - offset)].reduce(0,+) / Double(n)
    }
    public func relativeGain(versus benchmark: QuoteHistory, lookback: Int = 20) -> Double? {
        let a = Dictionary(uniqueKeysWithValues: zip(dates, closes))
        let b = Dictionary(uniqueKeysWithValues: zip(benchmark.dates, benchmark.closes))
        let common = Set(a.keys).intersection(b.keys).sorted()
        guard common.count > lookback,
              let first = common.dropLast(lookback).last, let last = common.last,
              let ai = a[first], let bi = b[first], let ae = a[last], let be = b[last], ai > 0, bi > 0, be > 0 else { return nil }
        return (ae / be) / (ai / bi) - 1
    }
}

public struct ScoreItem: Identifiable {
    public let name: String
    public let maxScore: Int
    public let score: Int?
    public let explanation: String
    public var id: String { name }
}
public struct Assessment {
    public let items: [ScoreItem]
    public let total: Int? // nil if ANY required component missing
    public let partial: Int
    public let availableMax: Int
    public let grade: String?
    public let vcp: String
    public let htf: String
}

public enum Scorer {
    public static func assess(_ snapshot: BreadthSnapshot?, _ quotes: [String: QuoteHistory]) -> Assessment {
        let q = snapshot?.quarterRatio
        let ratio10 = snapshot?.ratio(10)
        let ratio5 = snapshot?.ratio(5)
        let ratio3 = snapshot?.ratio(3)
        var items = [
            ScoreItem(name: "Stockbee Quarter Ratio", maxScore: 20, score: q.map { $0 >= 1.5 ? 20 : ($0 >= 1.0 ? 15 : ($0 >= 0.7 ? 8 : 0)) }, explanation: "≥1.5:20，≥1:15，≥0.7:8，否则0"),
            ScoreItem(name: "Stockbee 10D Ratio", maxScore: 15, score: ratio10.map { $0 >= 2 ? 15 : ($0 >= 1.3 ? 11 : ($0 >= 1 ? 7 : 0)) }, explanation: "≥2:15，≥1.3:11，≥1:7，否则0"),
            ScoreItem(name: "Stockbee 5D Ratio", maxScore: 5, score: ratio5.map { $0 >= 2 ? 5 : ($0 >= 1.3 ? 4 : ($0 >= 1 ? 3 : 0)) }, explanation: "≥2:5，≥1.3:4，≥1:3，否则0"),
            ScoreItem(name: "Stockbee 3D Ratio", maxScore: 5, score: ratio3.map { $0 >= 1.5 ? 5 : ($0 >= 1 ? 3 : 0) }, explanation: "≥1.5:5，≥1:3，否则0")
        ]
        // Both ETFs must be present, have enough history, AND have the same latest trading session.
        var trend: Int? = nil
        if let session = snapshot?.latest?.date, let spy = quotes["SPY"], let qqq = quotes["QQQ"],
           spy.lastDate == session, qqq.lastDate == session {
            func component(_ h: QuoteHistory) -> Int? {
                guard let close = h.lastClose, let ma20 = h.sma(20), let ma50 = h.sma(50), let prior20 = h.sma(20, offset: 5) else { return nil }
                return (close > ma20 ? 4 : 0) + (close > ma50 ? 5 : 0) + (ma20 > prior20 ? 3 : 0)
            }
            if let a = component(spy), let b = component(qqq) { trend = a + b + ((a == 12 && b == 12) ? 1 : 0) }
        }
        items.append(ScoreItem(name: "SPY/QQQ 指数趋势", maxScore: 25, score: trend, explanation: "各指数站上MA20 +4、站上MA50 +5、MA20走高 +3；两者全满足额外+1"))
        let breadth: Int? = snapshot?.latest?.t2108.map { t in
            t >= 70 ? 20 : (t >= 60 ? 17 : (t >= 50 ? 12 : (t >= 40 ? 7 : 0)))
        }
        items.append(ScoreItem(name: "T2108 / Russell 3000广度", maxScore: 20, score: breadth, explanation: "使用Stockbee的T2108代表广度（非Russell3000成分占比）；≥70%:20，≥60%:17，≥50%:12，≥40%:7，否则0"))
        var sector: Int? = nil
        if let session = snapshot?.latest?.date, let spy = quotes["SPY"], let xlk = quotes["XLK"], let smh = quotes["SMH"], let xly = quotes["XLY"],
           spy.lastDate == session, [xlk,smh,xly].allSatisfy({ $0.lastDate == session }),
           let a = xlk.relativeGain(versus: spy), let b = smh.relativeGain(versus: spy), let c = xly.relativeGain(versus: spy) {
            sector = (a > 0 ? 3 : 0) + (b > 0 ? 4 : 0) + (c > 0 ? 3 : 0)
        }
        items.append(ScoreItem(name: "XLK/SMH/XLY 板块领导力", maxScore: 10, score: sector, explanation: "近20个共同交易日相对SPY强势：XLK +3、SMH +4、XLY +3"))
        let complete = items.allSatisfy { $0.score != nil }
        let sum = items.compactMap(\.score).reduce(0, +)
        let max = items.filter { $0.score != nil }.reduce(0) { $0 + $1.maxScore }
        let total = complete ? sum : nil
        var grade: String? = nil
        if let n = total { grade = n >= 80 ? "A" : (n >= 65 ? "B" : (n >= 45 ? "C" : "D")) }
        let vcp = switch grade {
          case "A": "按计划参与；仍须满足个股Pivot、量能和止损条件"
          case "B": "精选领涨股，小仓位试单"
          case "C": "原则上观察，不追突破"
          case "D": "暂停新开VCP突破仓位"
          default: "数据不完整，暂不建议依据环境评分开新仓"
        }
        let htf = switch grade {
          case "A": "可参与；等待高紧旗形整理和有效突破"
          case "B": "仅极强领涨股、严格控制风险"
          case "C", "D": "暂停新开HTF仓位"
          default: "数据不完整，暂停基于评分的HTF信号"
        }
        return Assessment(items: items, total: total, partial: sum, availableMax: max, grade: grade, vcp: vcp, htf: htf)
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
        let formats = ["MMM d, yyyy", "MMM dd, yyyy", "M/d/yyyy", "MM/dd/yyyy", "yyyy/M/d", "M/d/yy", "MM/dd/yy", "d MMM yyyy"]
        let input = DateFormatter(); input.locale = Locale(identifier: "en_US_POSIX"); input.timeZone = TimeZone(secondsFromGMT: 0)
        let out = DateFormatter(); out.locale = Locale(identifier: "en_US_POSIX"); out.timeZone = TimeZone(secondsFromGMT: 0); out.dateFormat = "yyyy-MM-dd"
        for fmt in formats { input.dateFormat = fmt; if let d = input.date(from: clean) { return out.string(from: d) } }
        return nil
    }
}
